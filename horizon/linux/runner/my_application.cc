#include "my_application.h"

#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "pty_manager.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  GtkStatusIcon* tray_icon;
  GtkWidget* tray_menu;
  gboolean allow_close;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void show_main_window(MyApplication* self) {
  if (self->window == nullptr) {
    return;
  }
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_present(self->window);
}

static void tray_menu_show(GtkMenuItem* /*menuitem*/, gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  show_main_window(self);
}

static void tray_menu_quit(GtkMenuItem* /*menuitem*/, gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  const char* home = g_get_home_dir();
  if (home != nullptr) {
    std::string pid_path = std::string(home) + "/.blackhole/horizon/daemon.pid";
    std::ifstream pid_file(pid_path);
    if (pid_file) {
      std::string pid_text;
      std::getline(pid_file, pid_text);
      pid_t pid = static_cast<pid_t>(std::strtol(pid_text.c_str(), nullptr, 10));
      if (pid > 0) {
        kill(pid, SIGTERM);
      }
      std::remove(pid_path.c_str());
    }
  }
  self->allow_close = TRUE;
  if (self->window != nullptr) {
    gtk_window_close(self->window);
  }
  g_application_quit(G_APPLICATION(self));
}

static void tray_icon_activate(GtkStatusIcon* /*status_icon*/, gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  show_main_window(self);
}

static void tray_icon_popup_menu(GtkStatusIcon* status_icon,
                                 guint button,
                                 guint activate_time,
                                 gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  if (self->tray_menu == nullptr) {
    return;
  }
  gtk_menu_popup(
      GTK_MENU(self->tray_menu),
      nullptr,
      nullptr,
      gtk_status_icon_position_menu,
      status_icon,
      button,
      activate_time);
}

static gboolean window_delete_event(GtkWidget* widget, GdkEvent* /*event*/, gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  if (self->allow_close) {
    return FALSE;  // allow close
  }
  if (self->tray_icon == nullptr || !gtk_status_icon_is_embedded(self->tray_icon)) {
    return FALSE;  // tray unavailable, allow close
  }
  gtk_widget_hide(widget);
  return TRUE;  // prevent close (keep running)
}

static void ensure_tray(MyApplication* self) {
  if (self->tray_icon != nullptr) {
    return;
  }
  self->tray_icon = gtk_status_icon_new_from_file("resources/app_icon.png");
  if (self->tray_icon == nullptr) {
    // Fallback to a theme icon if the bundled icon can't be loaded.
    self->tray_icon = gtk_status_icon_new_from_icon_name("utilities-terminal");
  }
  gtk_status_icon_set_tooltip_text(self->tray_icon, "Horizon");
  gtk_status_icon_set_visible(self->tray_icon, TRUE);
  g_signal_connect(self->tray_icon, "activate", G_CALLBACK(tray_icon_activate), self);
  g_signal_connect(
      self->tray_icon,
      "popup-menu",
      G_CALLBACK(tray_icon_popup_menu),
      self);

  self->tray_menu = gtk_menu_new();
  GtkWidget* show_item = gtk_menu_item_new_with_label("Show Horizon");
  g_signal_connect(show_item, "activate", G_CALLBACK(tray_menu_show), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), show_item);

  GtkWidget* sep = gtk_separator_menu_item_new();
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), sep);

  GtkWidget* quit_item = gtk_menu_item_new_with_label("Quit");
  g_signal_connect(quit_item, "activate", G_CALLBACK(tray_menu_quit), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), quit_item);

  gtk_widget_show_all(self->tray_menu);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Horizon");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Horizon");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // Set window icon
  GError* icon_error = nullptr;
  GdkPixbuf* icon = gdk_pixbuf_new_from_file("resources/app_icon.png", &icon_error);
  if (icon != nullptr) {
    gtk_window_set_icon(window, icon);
    g_object_unref(icon);
  } else {
    g_clear_error(&icon_error);
  }

  self->window = window;
  self->allow_close = FALSE;
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event), self);
  ensure_tray(self);

  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Register PTY manager plugin
  FlPluginRegistrar* registrar = fl_plugin_registry_get_registrar_for_plugin(
      FL_PLUGIN_REGISTRY(view), "PtyManagerPlugin");
  pty_manager_register_with_registrar(registrar);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  if (self->tray_menu != nullptr) {
    gtk_widget_destroy(self->tray_menu);
    self->tray_menu = nullptr;
  }
  if (self->tray_icon != nullptr) {
    g_object_unref(self->tray_icon);
    self->tray_icon = nullptr;
  }
  self->window = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->dart_entrypoint_arguments = nullptr;
  self->window = nullptr;
  self->tray_icon = nullptr;
  self->tray_menu = nullptr;
  self->allow_close = FALSE;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}

/// TUN device creation and configuration for macOS and Linux.
///
/// On macOS this uses the utun kernel control interface via PF_SYSTEM sockets.
/// On Linux this uses the /dev/net/tun character device with TUNSETIFF.
use std::process::Command;

// ---------------------------------------------------------------------------
// TunDevice
// ---------------------------------------------------------------------------

/// A TUN network interface backed by a file descriptor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TunTransport {
    NativeTun,
    PacketSocket,
}

pub struct TunDevice {
    /// The raw file descriptor for the TUN device.
    pub fd: i32,
    /// The assigned interface name (e.g. "utun3" on macOS, "tun0" on Linux).
    pub name: String,
    /// How packets should be interpreted on this fd.
    pub transport: TunTransport,
}

impl Drop for TunDevice {
    fn drop(&mut self) {
        if self.fd >= 0 {
            unsafe {
                libc::close(self.fd);
            }
            self.fd = -1;
        }
    }
}

// ---------------------------------------------------------------------------
// Non-blocking helper (shared across platforms)
// ---------------------------------------------------------------------------

/// Set the `O_NONBLOCK` flag on a file descriptor.
fn set_nonblocking(fd: i32) -> Result<(), String> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 {
            return Err(format!(
                "fcntl F_GETFL failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        if libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return Err(format!(
                "fcntl F_SETFL O_NONBLOCK failed: {}",
                std::io::Error::last_os_error()
            ));
        }
    }
    Ok(())
}

// ===========================================================================
// macOS (utun) implementation
// ===========================================================================

#[cfg(target_os = "macos")]
mod platform {
    use super::*;

    // Constants not always exposed by libc on macOS.
    const PF_SYSTEM: libc::c_int = libc::AF_SYSTEM;
    const SYSPROTO_CONTROL: libc::c_int = 2;
    const AF_SYS_CONTROL: libc::c_int = 2;
    const UTUN_CONTROL_NAME: &str = "com.apple.net.utun_control";

    // ioctl request code for CTLIOCGINFO (macOS specific).
    const CTLIOCGINFO: libc::c_ulong = 0xc0644e03;

    #[repr(C)]
    struct ctl_info {
        ctl_id: u32,
        ctl_name: [u8; 96],
    }

    #[repr(C)]
    struct sockaddr_ctl {
        sc_len: u8,
        sc_family: u8,
        ss_sysaddr: u16,
        sc_id: u32,
        sc_unit: u32,
        sc_reserved: [u32; 5],
    }

    /// Create a TUN device via the macOS utun kernel control interface.
    ///
    /// If `name_hint` is provided and has the form `"utunN"`, we request that
    /// specific unit number. Otherwise the kernel assigns the next available
    /// utun interface.
    pub fn create_tun(name_hint: Option<&str>) -> Result<TunDevice, String> {
        // 1. Create a PF_SYSTEM socket.
        let fd = unsafe { libc::socket(PF_SYSTEM, libc::SOCK_DGRAM, SYSPROTO_CONTROL) };
        if fd < 0 {
            return Err(format!(
                "socket(PF_SYSTEM) failed: {}",
                std::io::Error::last_os_error()
            ));
        }

        // 2. Look up the control ID for com.apple.net.utun_control.
        let mut info = ctl_info {
            ctl_id: 0,
            ctl_name: [0u8; 96],
        };
        let name_bytes = UTUN_CONTROL_NAME.as_bytes();
        info.ctl_name[..name_bytes.len()].copy_from_slice(name_bytes);

        if unsafe { libc::ioctl(fd, CTLIOCGINFO, &mut info as *mut _) } < 0 {
            let err = std::io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(format!("ioctl CTLIOCGINFO failed: {}", err));
        }

        // 3. Connect with a sockaddr_ctl.
        //    sc_unit = 0 means auto-assign; sc_unit = N+1 requests utunN.
        let sc_unit: u32 = name_hint
            .and_then(|hint| hint.strip_prefix("utun"))
            .and_then(|num_str| num_str.parse::<u32>().ok())
            .map(|n| n + 1)
            .unwrap_or(0);

        let addr = sockaddr_ctl {
            sc_len: std::mem::size_of::<sockaddr_ctl>() as u8,
            sc_family: libc::AF_SYSTEM as u8,
            ss_sysaddr: AF_SYS_CONTROL as u16,
            sc_id: info.ctl_id,
            sc_unit,
            sc_reserved: [0u32; 5],
        };

        if unsafe {
            libc::connect(
                fd,
                &addr as *const sockaddr_ctl as *const libc::sockaddr,
                std::mem::size_of::<sockaddr_ctl>() as libc::socklen_t,
            )
        } < 0
        {
            let err = std::io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(format!("connect(utun) failed: {}", err));
        }

        // 4. Retrieve the assigned interface name via getsockopt.
        let mut if_name = [0u8; 256];
        let mut if_name_len: libc::socklen_t = if_name.len() as libc::socklen_t;

        // UTUN_OPT_IFNAME = 2
        if unsafe {
            libc::getsockopt(
                fd,
                SYSPROTO_CONTROL,
                2, // UTUN_OPT_IFNAME
                if_name.as_mut_ptr() as *mut libc::c_void,
                &mut if_name_len,
            )
        } < 0
        {
            let err = std::io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(format!("getsockopt UTUN_OPT_IFNAME failed: {}", err));
        }

        let name = std::ffi::CStr::from_bytes_until_nul(&if_name[..if_name_len as usize])
            .map_err(|e| {
                unsafe {
                    libc::close(fd);
                }
                format!("failed to parse utun name: {}", e)
            })?
            .to_str()
            .map_err(|e| {
                unsafe {
                    libc::close(fd);
                }
                format!("utun name is not valid UTF-8: {}", e)
            })?
            .to_string();

        // 5. Set non-blocking.
        set_nonblocking(fd).map_err(|e| {
            unsafe {
                libc::close(fd);
            }
            e
        })?;

        Ok(TunDevice {
            fd,
            name,
            transport: TunTransport::NativeTun,
        })
    }

    /// Configure the IP address and netmask on a TUN device (macOS).
    ///
    /// Also adds a subnet route through the TUN because macOS only creates a
    /// host route for the point-to-point peer address; without the explicit
    /// subnet route, traffic to other VPN client IPs won't traverse the TUN.
    pub fn configure_tun(device: &TunDevice, ip: &str, netmask: &str) -> Result<(), String> {
        let output = Command::new("ifconfig")
            .args([&device.name, ip, ip, "netmask", netmask])
            .output()
            .map_err(|e| format!("failed to run ifconfig: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "ifconfig failed (exit {}): {}",
                output.status.code().unwrap_or(-1),
                stderr.trim()
            ));
        }

        // Derive the network CIDR from IP + netmask for the route command.
        // Parse the IP and netmask to compute the network address.
        if let (Ok(ip_addr), Ok(mask_addr)) = (
            ip.parse::<std::net::Ipv4Addr>(),
            netmask.parse::<std::net::Ipv4Addr>(),
        ) {
            let ip_bits = u32::from(ip_addr);
            let mask_bits = u32::from(mask_addr);
            let net_addr = std::net::Ipv4Addr::from(ip_bits & mask_bits);
            let prefix_len = mask_bits.count_ones();
            let cidr = format!("{}/{}", net_addr, prefix_len);

            let route_out = Command::new("route")
                .args(["-n", "add", "-net", &cidr, "-interface", &device.name])
                .output()
                .map_err(|e| format!("failed to run route add: {}", e))?;

            if !route_out.status.success() {
                let stderr = String::from_utf8_lossy(&route_out.stderr);
                // "File exists" means the route is already there — not an error.
                if !stderr.contains("File exists") {
                    return Err(format!(
                        "route add -net {} -interface {} failed: {}",
                        cidr,
                        device.name,
                        stderr.trim()
                    ));
                }
            }
        }

        Ok(())
    }
}

// ===========================================================================
// Linux TUN implementation
// ===========================================================================

#[cfg(target_os = "linux")]
mod platform {
    use super::*;

    const TUNSETIFF: libc::c_ulong = 0x400454ca;
    const IFF_TUN: libc::c_short = 0x0001;
    const IFF_NO_PI: libc::c_short = 0x1000;

    /// ifreq-style structure for TUNSETIFF.  Only the fields we need.
    #[repr(C)]
    struct ifreq {
        ifr_name: [u8; libc::IFNAMSIZ],
        ifr_flags: libc::c_short,
        _pad: [u8; 22], // remaining bytes to fill the union
    }

    /// Create a TUN device via `/dev/net/tun` on Linux.
    ///
    /// If `name_hint` is provided it is used as the requested interface name
    /// (e.g. `"tun0"`). Otherwise the kernel assigns a name.
    pub fn create_tun(name_hint: Option<&str>) -> Result<TunDevice, String> {
        // 1. Open /dev/net/tun
        let path = std::ffi::CString::new("/dev/net/tun").unwrap();
        let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDWR) };
        if fd < 0 {
            return Err(format!(
                "open(/dev/net/tun) failed: {}",
                std::io::Error::last_os_error()
            ));
        }

        // 2. Prepare ifreq and issue TUNSETIFF.
        let mut ifr = ifreq {
            ifr_name: [0u8; libc::IFNAMSIZ],
            ifr_flags: IFF_TUN | IFF_NO_PI,
            _pad: [0u8; 22],
        };

        if let Some(hint) = name_hint {
            let hint_bytes = hint.as_bytes();
            let copy_len = hint_bytes.len().min(libc::IFNAMSIZ - 1);
            ifr.ifr_name[..copy_len].copy_from_slice(&hint_bytes[..copy_len]);
        }

        if unsafe { libc::ioctl(fd, TUNSETIFF as libc::c_ulong, &mut ifr as *mut _) } < 0 {
            let err = std::io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(format!("ioctl TUNSETIFF failed: {}", err));
        }

        // Extract the assigned name from ifreq.
        let nul_pos = ifr
            .ifr_name
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(libc::IFNAMSIZ);
        let name = String::from_utf8_lossy(&ifr.ifr_name[..nul_pos]).to_string();

        // 3. Set non-blocking.
        set_nonblocking(fd).map_err(|e| {
            unsafe {
                libc::close(fd);
            }
            e
        })?;

        Ok(TunDevice {
            fd,
            name,
            transport: TunTransport::NativeTun,
        })
    }

    /// Configure the IP address on a TUN device (Linux).
    pub fn configure_tun(device: &TunDevice, ip: &str, _netmask: &str) -> Result<(), String> {
        // Add address.
        let output = Command::new("ip")
            .args(["addr", "add", &format!("{}/24", ip), "dev", &device.name])
            .output()
            .map_err(|e| format!("failed to run `ip addr add`: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "ip addr add failed (exit {}): {}",
                output.status.code().unwrap_or(-1),
                stderr.trim()
            ));
        }

        // Bring the link up.
        let output = Command::new("ip")
            .args(["link", "set", &device.name, "up"])
            .output()
            .map_err(|e| format!("failed to run `ip link set up`: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "ip link set up failed (exit {}): {}",
                output.status.code().unwrap_or(-1),
                stderr.trim()
            ));
        }

        Ok(())
    }
}

// ===========================================================================
// Unsupported platform stub
// ===========================================================================

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    use super::*;

    pub fn create_tun(_name_hint: Option<&str>) -> Result<TunDevice, String> {
        Err("TUN device creation is not supported on this platform".to_string())
    }

    pub fn configure_tun(_device: &TunDevice, _ip: &str, _netmask: &str) -> Result<(), String> {
        Err("TUN device configuration is not supported on this platform".to_string())
    }
}

// ===========================================================================
// Public API (delegates to platform module)
// ===========================================================================

/// Create a new TUN device.
///
/// On macOS, `name_hint` may be `"utunN"` to request a specific unit number.
/// On Linux, `name_hint` may be any valid interface name (e.g. `"tun0"`).
/// Pass `None` to let the kernel choose.
pub fn create_tun(name_hint: Option<&str>) -> Result<TunDevice, String> {
    platform::create_tun(name_hint)
}

/// Configure the IP address and netmask on an existing TUN device.
///
/// On macOS this calls `ifconfig`. On Linux this calls `ip addr add` and
/// `ip link set up`.
pub fn configure_tun(device: &TunDevice, ip: &str, netmask: &str) -> Result<(), String> {
    platform::configure_tun(device, ip, netmask)
}

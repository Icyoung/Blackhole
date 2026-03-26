use std::collections::HashMap;
use std::net::Ipv4Addr;

/// Manages VPN IP address allocation within a fixed subnet.
///
/// Default subnet: `10.13.37.0/24`
/// - `.1` is reserved for the Horizon server
/// - `.2` through `.254` are available for Voyager clients
///
/// Allocations are persistent per device key (a string identifier
/// unique to each connecting device).
pub struct IpPool {
    /// Base three octets of the subnet (e.g., [10, 13, 37]).
    base: [u8; 3],
    /// Maps device key to last octet of allocated IP.
    allocations: HashMap<String, u8>,
}

impl IpPool {
    /// Create a new IP pool with the default `10.13.37.0/24` subnet.
    /// The server address `.1` is implicitly reserved and will never be allocated.
    pub fn new() -> Self {
        Self {
            base: [10, 13, 37],
            allocations: HashMap::new(),
        }
    }

    /// Allocate an IP address for the given device key.
    ///
    /// If the device already has an allocation, returns the same address.
    /// Otherwise, assigns the next available address in `.2` through `.254`.
    /// Returns `None` if the pool is exhausted.
    pub fn allocate(&mut self, device_key: &str) -> Option<Ipv4Addr> {
        // Return existing allocation if present.
        if let Some(&octet) = self.allocations.get(device_key) {
            return Some(self.addr_from_octet(octet));
        }

        // Find the next free octet in the range 2..=254.
        let used: std::collections::HashSet<u8> = self.allocations.values().copied().collect();
        for candidate in 2..=254u8 {
            if !used.contains(&candidate) {
                self.allocations.insert(device_key.to_string(), candidate);
                return Some(self.addr_from_octet(candidate));
            }
        }

        // Pool exhausted.
        None
    }

    /// Release the IP allocation for the given device key.
    /// The address becomes available for future allocations.
    pub fn release(&mut self, device_key: &str) {
        self.allocations.remove(device_key);
    }

    /// Get the current IP allocation for a device key, if any.
    pub fn get_allocation(&mut self, device_key: &str) -> Option<Ipv4Addr> {
        self.allocations
            .get(device_key)
            .map(|&octet| self.addr_from_octet(octet))
    }

    /// Build an Ipv4Addr from the base octets and a last octet.
    fn addr_from_octet(&self, last: u8) -> Ipv4Addr {
        Ipv4Addr::new(self.base[0], self.base[1], self.base[2], last)
    }
}

impl Default for IpPool {
    fn default() -> Self {
        Self::new()
    }
}

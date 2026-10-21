//! App lock: a PIN asked for at start-up (and on "Lock now"). Only a salted
//! SHA-256 hash is kept, in the OS credential store.

use base64::Engine as _;
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};

pub const PIN_MIN: usize = 4;
pub const PIN_MAX: usize = 8;
const KEY: &str = "app_lock_pin";

fn hash(salt: &str, pin: &str) -> String {
    let digest = Sha256::digest(format!("{salt}{pin}").as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// `salt:hash` for a new PIN.
fn encode(pin: &str) -> String {
    let mut bytes = [0u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        // Practically never; still salt with something unpredictable-ish.
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
        bytes = t.to_le_bytes();
    }
    let salt = base64::engine::general_purpose::STANDARD.encode(bytes);
    format!("{salt}:{}", hash(&salt, pin))
}

fn matches(stored: &str, pin: &str) -> bool {
    match stored.split_once(':') {
        Some((salt, h)) if !salt.is_empty() => hash(salt, pin) == h,
        _ => false,
    }
}

pub fn valid_pin(pin: &str) -> bool {
    (PIN_MIN..=PIN_MAX).contains(&pin.len()) && pin.bytes().all(|b| b.is_ascii_digit())
}

pub struct Lock {
    stored: Option<String>,
    pub locked: bool,
    /// The app is only built after the first unlock, so nothing (autoplay,
    /// playlist refresh) runs behind the lock screen at start-up.
    pub ever_unlocked: bool,
    failures: u32,
    blocked_until: Option<Instant>,
}

impl Lock {
    /// Reads the stored PIN (call before the window opens).
    pub fn load() -> Self {
        let stored = crate::secrets::get(KEY);
        let enabled = stored.is_some();
        Self { stored, locked: enabled, ever_unlocked: !enabled, failures: 0, blocked_until: None }
    }

    pub fn enabled(&self) -> bool {
        self.stored.is_some()
    }

    /// Time left before another attempt is allowed.
    pub fn cooldown(&self) -> Duration {
        self.blocked_until.map_or(Duration::ZERO, |t| t.saturating_duration_since(Instant::now()))
    }

    /// Checks a PIN. After 5 wrong tries every further attempt waits a
    /// growing cooldown (30 s, 60 s, …).
    pub fn verify(&mut self, pin: &str) -> bool {
        if self.cooldown() > Duration::ZERO {
            return false;
        }
        if self.stored.as_deref().is_some_and(|s| matches(s, pin)) {
            self.failures = 0;
            return true;
        }
        self.failures += 1;
        if self.failures >= 5 {
            self.blocked_until = Some(Instant::now() + Duration::from_secs(30 * u64::from(self.failures - 4)));
        }
        false
    }

    pub fn unlock(&mut self, pin: &str) -> bool {
        let ok = self.verify(pin);
        if ok {
            self.locked = false;
            self.ever_unlocked = true;
        }
        ok
    }

    pub fn enable(&mut self, pin: &str) {
        let stored = encode(pin);
        crate::secrets::set(KEY, &stored);
        self.stored = Some(stored);
        self.locked = false;
        self.ever_unlocked = true;
    }

    pub fn disable(&mut self) {
        crate::secrets::remove(KEY);
        self.stored = None;
        self.locked = false;
    }

    pub fn lock_now(&mut self) {
        if self.enabled() {
            self.locked = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lock_with(pin: &str) -> Lock {
        Lock { stored: Some(encode(pin)), locked: true, ever_unlocked: false, failures: 0, blocked_until: None }
    }

    #[test]
    fn hashes_with_salt() {
        let a = encode("1234");
        let b = encode("1234");
        assert_ne!(a, b, "salted");
        assert!(matches(&a, "1234") && !matches(&a, "4321"));
        assert!(!matches("garbage", "1234"));
        assert!(valid_pin("0000") && !valid_pin("123") && !valid_pin("12a4") && !valid_pin("123456789"));
    }

    #[test]
    fn unlocks_and_cools_down() {
        let mut l = lock_with("2468");
        assert!(!l.unlock("1111"));
        assert!(l.locked);
        assert!(l.unlock("2468"));
        assert!(!l.locked && l.ever_unlocked);
        for _ in 0..5 {
            assert!(!l.verify("0000"));
        }
        assert!(l.cooldown() > Duration::from_secs(25));
        // Even the right PIN waits out the cooldown.
        assert!(!l.verify("2468"));
    }
}

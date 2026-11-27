//! FxHash (rustc's multiply-rotate hash) for the translator's tables. Their
//! keys are small integers and values made of them; with SipHash, the
//! standard library's default, hashing took a large share of a translation.

use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasherDefault, Hasher};

pub(crate) type Map<K, V> = HashMap<K, V, BuildHasherDefault<Fx>>;
pub(crate) type Set<K> = HashSet<K, BuildHasherDefault<Fx>>;

/// FxHash's multiply-rotate step.
#[derive(Default)]
pub(crate) struct Fx(u64);

impl Hasher for Fx {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.write_u64(u64::from(b));
        }
    }

    fn write_u32(&mut self, n: u32) {
        self.write_u64(u64::from(n));
    }

    fn write_u64(&mut self, n: u64) {
        self.0 = (self.0.rotate_left(5) ^ n).wrapping_mul(0x517c_c1b7_2722_0a95);
    }

    fn write_usize(&mut self, n: usize) {
        self.write_u64(n as u64);
    }
}

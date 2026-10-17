//! Frozen, interned Strings for env keys and a few fixed CGI values, so each
//! request's env reuses them instead of allocating one String per param.
//!
//! The table only grows, and only up to [`CAPACITY`] entries per kind: header
//! names reach it from clients, and past the cap a name gets a fresh String,
//! as without the table. Every interned String is kept alive by one rooted
//! Array; the table holds no lock while it calls into Ruby, since a Ruby call
//! can switch threads and another thread's lookup would then deadlock.

use std::{
    collections::HashMap,
    sync::{LazyLock, Mutex, OnceLock, PoisonError},
};

use magnus::{Error, RArray, RString, Ruby, value::Opaque};

use crate::OrProtocolError;

const CAPACITY: usize = 1024;

#[derive(Default)]
struct Table {
    /// Env keys: UTF-8 when the name is, binary otherwise
    keys: HashMap<Box<[u8]>, Opaque<RString>>,
    /// Env values: binary, like every other param value
    values: HashMap<Box<[u8]>, Opaque<RString>>,
}

#[derive(Clone, Copy)]
enum Kind {
    Key,
    Value,
}

impl Table {
    const fn strings(&mut self, kind: Kind) -> &mut HashMap<Box<[u8]>, Opaque<RString>> {
        match kind {
            Kind::Key => &mut self.keys,
            Kind::Value => &mut self.values,
        }
    }
}

static TABLE: LazyLock<Mutex<Table>> = LazyLock::new(Mutex::default);
static ROOT: OnceLock<Opaque<RArray>> = OnceLock::new();

/// Create the Array that keeps interned Strings alive. Called once, at load.
pub fn init(ruby: &Ruby) {
    let root = ruby.ary_new();
    ruby.gc_register_mark_object(root);
    crate::cache(&ROOT, root);
}

/// The env key for a param name.
pub fn key(ruby: &Ruby, name: &[u8]) -> Result<RString, Error> {
    intern(ruby, Kind::Key, name)
}

/// A shared, frozen param value.
pub fn value(ruby: &Ruby, value: &[u8]) -> Result<RString, Error> {
    intern(ruby, Kind::Value, value)
}

fn intern(ruby: &Ruby, kind: Kind, bytes: &[u8]) -> Result<RString, Error> {
    if let Some(found) = lock().strings(kind).get(bytes) {
        return Ok(ruby.get_inner(*found));
    }

    let fresh = match kind {
        Kind::Key => std::str::from_utf8(bytes)
            .map_or_else(|_| ruby.str_from_slice(bytes), |name| ruby.str_new(name)),
        Kind::Value => ruby.str_from_slice(bytes),
    };
    let interned = fresh.to_interned_str();

    let mut table = lock();
    let strings = table.strings(kind);
    if strings.len() >= CAPACITY || strings.contains_key(bytes) {
        return Ok(interned);
    }
    strings.insert(bytes.into(), Opaque::from(interned));
    drop(table);

    let root = ROOT.get().ok_or("interned strings were not initialised").or_protocol_error(ruby)?;
    ruby.get_inner(*root).push(interned)?;
    Ok(interned)
}

/// The table holds plain maps that stay consistent even if a holder
/// panicked, so a poisoned lock is still safe to use.
fn lock() -> std::sync::MutexGuard<'static, Table> {
    TABLE.lock().unwrap_or_else(PoisonError::into_inner)
}

use std::{fmt::Display, sync::OnceLock};

use magnus::{
    Error, ExceptionClass, Module, Object, RClass, RModule, Ruby, Value, function, method,
    value::{Opaque, ReprValue},
};

macro_rules! ensure {
    ($ruby:expr, $cond:expr, $($message:tt)+) => {
        if !$cond {
            return Err($crate::protocol_error($ruby, format!($($message)+)));
        }
    };
}

mod codec;
mod headers;
mod link;

use codec::Codec;

static PROTOCOL_ERROR: OnceLock<Opaque<ExceptionClass>> = OnceLock::new();
static STRING_IO: OnceLock<Opaque<RClass>> = OnceLock::new();
static ENGINE: OnceLock<Opaque<RModule>> = OnceLock::new();

pub(crate) fn protocol_error(ruby: &Ruby, message: impl Into<String>) -> Error {
    let class = cached(ruby, &PROTOCOL_ERROR).unwrap_or_else(|| ruby.exception_runtime_error());
    Error::new(class, message.into())
}

pub(crate) trait OrProtocolError<T> {
    fn or_protocol_error(self, ruby: &Ruby) -> Result<T, Error>;
}

impl<T, E: Display> OrProtocolError<T> for Result<T, E> {
    fn or_protocol_error(self, ruby: &Ruby) -> Result<T, Error> {
        self.map_err(|error| protocol_error(ruby, error.to_string()))
    }
}

pub(crate) fn spool_file(ruby: &Ruby) -> Result<Value, Error> {
    initialised(ruby, &ENGINE, "Shuttlebay::Engine was not initialised")?.funcall("spool_file", ())
}

pub(crate) fn string_io(ruby: &Ruby) -> Result<RClass, Error> {
    initialised(ruby, &STRING_IO, "StringIO was not resolved at load time")
}

fn cache<T: ReprValue>(cell: &OnceLock<Opaque<T>>, value: T) {
    let _ = cell.set(Opaque::from(value));
}

fn cached<T: ReprValue>(ruby: &Ruby, cell: &OnceLock<Opaque<T>>) -> Option<T> {
    cell.get().map(|value| ruby.get_inner(*value))
}

fn initialised<T: ReprValue>(
    ruby: &Ruby,
    cell: &OnceLock<Opaque<T>>,
    missing: &'static str,
) -> Result<T, Error> {
    cached(ruby, cell).ok_or(missing).or_protocol_error(ruby)
}

#[magnus::init(name = "shuttlebay")]
fn init(ruby: &Ruby) -> Result<(), Error> {
    ruby.require("stringio")?;
    cache(&STRING_IO, ruby.class_object().const_get::<_, RClass>("StringIO")?);

    let shuttlebay = ruby.define_module("Shuttlebay")?;
    let engine = shuttlebay.define_module("Engine")?;
    cache(&ENGINE, engine);
    engine.const_set("VERSION", env!("CARGO_PKG_VERSION"))?;
    engine.const_set("SPOOL_THRESHOLD", codec::SPOOL_THRESHOLD)?;
    engine.const_set("PROTOCOL_VERSION", mothership_docking_protocol::VERSION)?;
    engine.const_set("HAUL_CHUNK_LEN", mothership_docking_protocol::HAUL_CHUNK_LEN)?;

    cache(&PROTOCOL_ERROR, engine.define_error("ProtocolError", ruby.exception_standard_error())?);

    let codec = engine.define_class("Codec", ruby.class_object())?;
    codec.define_singleton_method("new", function!(Codec::new, 0))?;
    codec.define_method("dock", method!(Codec::dock, 3))?;
    codec.define_method("read_request", method!(Codec::read_request, 2))?;
    codec.define_method("reply", method!(Codec::reply, -1))?;
    codec.define_method("write", method!(Codec::write, 2))?;
    codec.define_method("flush", method!(Codec::flush, 1))?;
    codec.define_method("finish", method!(Codec::finish, 1))?;
    codec.define_method("ready", method!(Codec::ready, 1))?;
    codec.define_method("tunnel_read", method!(Codec::tunnel_read, 1))?;
    codec.define_method("tunnel_write", method!(Codec::tunnel_write, 2))?;
    codec.define_method("tunnel_close", method!(Codec::tunnel_close, 1))?;
    codec.define_method("request_id", method!(Codec::request_id, 0))?;
    Ok(())
}

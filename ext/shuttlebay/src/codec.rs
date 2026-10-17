use std::{cell::RefCell, fmt::Display};

use magnus::{
    Error, RArray, RHash, RString, Ruby, Symbol, Value, prelude::*, scan_args::scan_args,
};
use mothership_docking_protocol::{
    Dock, HAUL_CHUNK_LEN, Hail, MAX_FRAME_PAYLOAD, MessageType, Moored, Pair, ProtocolError, Reply,
    ReplyBody, VERSION, decode_hail, decode_haul, decode_header, encode_dock, encode_haul_header,
    encode_ready, encode_reply, push_haul,
};

use crate::{
    OrProtocolError, headers, interned,
    link::{self, LinkEvent, LinkState},
    null_input, protocol_error, spool_file, string_io,
};

const READ_CHUNK: usize = 64 * 1024;
const FLUSH_THRESHOLD: usize = 64 * 1024;
pub const SPOOL_THRESHOLD: u64 = 1024 * 1024;

const MAX_BODY: u64 = 4 * 1024 * 1024 * 1024;

/// CGI params whose values come from a small set and that apps replace
/// rather than mutate: each value is one shared frozen String.
const SHARED_VALUES: [&[u8]; 6] = [
    b"REQUEST_METHOD",
    b"SCRIPT_NAME",
    b"SERVER_PORT",
    b"SERVER_PROTOCOL",
    b"SERVER_SOFTWARE",
    b"HTTPS",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Empty,
    Stream,
    File,
    Tunnel,
}

struct State {
    inbox: Vec<u8>,
    outbox: Vec<u8>,
    link: link::Machine,
}

impl Default for State {
    fn default() -> Self {
        Self { inbox: Vec::new(), outbox: Vec::new(), link: link::new() }
    }
}

#[magnus::wrap(class = "Shuttlebay::Engine::Codec", free_immediately, size)]
pub struct Codec {
    state: RefCell<State>,
}

impl Codec {
    pub fn new() -> Self {
        Self { state: RefCell::new(State::default()) }
    }

    pub fn dock(
        ruby: &Ruby,
        rb_self: &Self,
        io: Value,
        ship_name: String,
        threads: u16,
    ) -> Result<RHash, Error> {
        let dock = Dock::new(ship_name).with_pid(std::process::id()).with_threads(threads);
        let frame = encode_dock(&dock);
        rb_self.with_state(ruby, |state| state.outbox.extend_from_slice(&frame))?;
        rb_self.flush_to(ruby, io)?;

        let payload = rb_self
            .read_frame(ruby, io, MessageType::Moored)?
            .ok_or("Mothership closed the link before MOORED")
            .or_protocol_error(ruby)?;
        let moored: Moored = serde_json::from_slice(&payload)
            .map_err(|error| protocol_error(ruby, format!("Invalid MOORED payload: {error}")))?;
        ensure!(
            ruby,
            moored.version >= VERSION,
            "Mothership speaks docking protocol v{}, shuttlebay needs v{VERSION}",
            moored.version
        );

        let config = ruby.hash_new_capa(moored.config.len());
        for (key, value) in moored.config {
            config.aset(key, value)?;
        }
        Ok(config)
    }

    pub fn read_request(
        ruby: &Ruby,
        rb_self: &Self,
        io: Value,
        template: RHash,
    ) -> Result<Option<RHash>, Error> {
        ensure!(
            ruby,
            rb_self.with_state(ruby, |state| state.link.current_state() == LinkState::Idle)?,
            "read_request called before the previous ready"
        );

        let Some(payload) = rb_self.read_frame(ruby, io, MessageType::Hail)? else {
            return Ok(None);
        };
        let hail = decode_hail(&payload).or_protocol_error(ruby)?;
        let input = rb_self.read_body(ruby, io, &hail)?;

        let env: RHash = template.funcall("dup", ())?;
        for (name, value) in &hail.params {
            let value = if shares_value(name, value) {
                interned::value(ruby, value)?
            } else {
                ruby.str_from_slice(value)
            };
            env.aset(interned::key(ruby, name)?, value)?;
        }
        let secure = hail.params.iter().any(|(name, value)| name == b"HTTPS" && value == b"on");
        let scheme: &[u8] = if secure { b"https" } else { b"http" };
        env.aset(interned::key(ruby, b"rack.url_scheme")?, interned::value(ruby, scheme)?)?;
        env.aset(interned::key(ruby, b"rack.input")?, input)?;

        rb_self.try_with_state(ruby, |state| link::begin(&mut state.link, hail.request_id))?;
        Ok(Some(env))
    }

    pub fn reply(ruby: &Ruby, rb_self: &Self, args: &[Value]) -> Result<(), Error> {
        let args =
            scan_args::<(Value, i64, RHash, Symbol), (Option<Option<RString>>,), (), (), (), ()>(
                args,
            )?;
        let (_io, status, headers, kind) = args.required;
        let (path,) = args.optional;
        let path = path.flatten();

        let status = http_status(ruby, status)?;
        let kind = match kind.name()?.as_ref() {
            "empty" => Kind::Empty,
            "stream" => Kind::Stream,
            "file" => Kind::File,
            "tunnel" => Kind::Tunnel,
            other => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!("reply kind must be :empty, :stream, :file or :tunnel, got :{other}"),
                ));
            }
        };
        let body = match (kind, path) {
            (Kind::Empty, None) => ReplyBody::Empty,
            (Kind::Stream, None) => ReplyBody::Stream,
            (Kind::Tunnel, None) => ReplyBody::Tunnel,
            (Kind::File, Some(path)) => ReplyBody::File(path.to_bytes().to_vec()),
            (Kind::File, None) => {
                return Err(Error::new(ruby.exception_arg_error(), "file reply needs a path"));
            }
            (Kind::Empty | Kind::Stream | Kind::Tunnel, Some(_)) => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    "only file replies take a path",
                ));
            }
        };
        let headers = headers::flatten(ruby, headers)?;

        let event = match kind {
            Kind::Stream => LinkEvent::ReplyStream,
            Kind::Empty | Kind::File => LinkEvent::ReplyWhole,
            Kind::Tunnel => LinkEvent::ReplyTunnel,
        };
        rb_self.try_with_state(ruby, |state| -> Result<(), &str> {
            push_reply(state, event, status, headers, body).map(drop)
        })
    }

    /// Send a whole response at once: Reply head, body and FIN leave in one
    /// write, so Mothership always lands it as a complete body. A single chunk
    /// (a rendered page) is handed to the socket as is, never copied into a
    /// frame buffer; several are framed together.
    pub fn reply_whole(
        ruby: &Ruby,
        rb_self: &Self,
        io: Value,
        status: i64,
        headers: RHash,
        chunks: RArray,
    ) -> Result<(), Error> {
        let status = http_status(ruby, status)?;
        let headers = headers::flatten(ruby, headers)?;
        // Checked before the link moves, so a bad body still gets a 500.
        for index in 0..chunks.len() {
            body_chunk(ruby, chunks, index)?;
        }
        let only = (chunks.len() == 1)
            .then(|| body_chunk(ruby, chunks, 0))
            .transpose()?
            .filter(|chunk| chunk.len() <= HAUL_CHUNK_LEN);

        let request_id = rb_self.try_with_state(ruby, |state| {
            push_reply(state, LinkEvent::ReplyStream, status, headers, ReplyBody::Stream)
        })?;

        if let Some(chunk) = only {
            rb_self.try_with_state(ruby, |state| -> Result<(), &str> {
                let haul = encode_haul_header(request_id, true, chunk.len())
                    .map_err(|_| "body chunk exceeds the frame size limit")?;
                state.outbox.extend_from_slice(&haul);
                finish_stream(state)
            })?;
            let head = rb_self.with_state(ruby, |state| std::mem::take(&mut state.outbox))?;
            // A tuple keeps both Strings on the stack, visible to the GC,
            // for the whole write.
            let _: Value = io.funcall("write", (ruby.str_from_slice(&head), chunk))?;
            return Ok(());
        }

        for index in 0..chunks.len() {
            let bytes = body_chunk(ruby, chunks, index)?.to_bytes();
            rb_self.try_with_state(ruby, |state| {
                push_body(&mut state.outbox, request_id, &bytes, false)
                    .map_err(|_| "body chunk exceeds the frame size limit")
            })?;
        }
        rb_self.try_with_state(ruby, |state| -> Result<(), &str> {
            push_haul(&mut state.outbox, request_id, true, &[])
                .map_err(|_| "FIN frame could not be encoded")?;
            finish_stream(state)
        })?;
        rb_self.flush_to(ruby, io)
    }

    pub fn write(ruby: &Ruby, rb_self: &Self, io: Value, chunk: RString) -> Result<(), Error> {
        let chunk = chunk.to_bytes();
        let pending = rb_self.try_with_state(ruby, |state| -> Result<_, &str> {
            let request_id = link::request_in(
                &state.link,
                LinkState::Streaming,
                "write called without a request",
                "write needs a :stream reply first",
            )?;
            push_body(&mut state.outbox, request_id, &chunk, false)
                .map_err(|_| "body chunk exceeds the frame size limit")?;
            Ok(state.outbox.len())
        })?;
        if pending >= FLUSH_THRESHOLD {
            rb_self.flush_to(ruby, io)?;
        }
        Ok(())
    }

    pub fn tunnel_write(
        ruby: &Ruby,
        rb_self: &Self,
        io: Value,
        data: RString,
    ) -> Result<(), Error> {
        let data = data.to_bytes();
        rb_self.push_tunnel(ruby, &data, false)?;
        rb_self.flush_to(ruby, io)
    }

    pub fn tunnel_close(ruby: &Ruby, rb_self: &Self, io: Value) -> Result<(), Error> {
        rb_self.push_tunnel(ruby, &[], true)?;
        rb_self.flush_to(ruby, io)
    }

    pub fn tunnel_read(ruby: &Ruby, rb_self: &Self, io: Value) -> Result<Option<RString>, Error> {
        let request_id = rb_self.try_with_state(ruby, |state| {
            link::request_in(
                &state.link,
                LinkState::Tunnelling,
                "tunnel_read needs a :tunnel reply",
                "tunnel_read needs a :tunnel reply",
            )
        })?;
        loop {
            let Some(payload) = rb_self.read_frame(ruby, io, MessageType::Haul)? else {
                return Ok(None);
            };
            let haul = decode_haul(&payload).or_protocol_error(ruby)?;
            ensure!(ruby, haul.request_id == request_id, "tunnel frame for another request");
            if haul.fin {
                return Ok(None);
            }
            if !haul.data.is_empty() {
                return Ok(Some(ruby.str_from_slice(haul.data)));
            }
        }
    }

    fn push_tunnel(&self, ruby: &Ruby, data: &[u8], fin: bool) -> Result<(), Error> {
        self.try_with_state(ruby, |state| {
            let request_id = link::request_in(
                &state.link,
                LinkState::Tunnelling,
                "tunnel used without a request",
                "tunnel used without a :tunnel reply",
            )?;
            let pushed = if data.is_empty() {
                push_haul(&mut state.outbox, request_id, fin, &[])
            } else {
                push_body(&mut state.outbox, request_id, data, fin)
            };
            pushed.map_err(|_| "tunnel frame could not be encoded")
        })
    }

    pub fn flush(ruby: &Ruby, rb_self: &Self, io: Value) -> Result<(), Error> {
        rb_self.flush_to(ruby, io)
    }

    pub fn finish(ruby: &Ruby, rb_self: &Self, io: Value) -> Result<(), Error> {
        rb_self.try_with_state(ruby, |state| -> Result<(), &str> {
            let (request_id, from) =
                link::advance(&mut state.link, LinkEvent::Finish, |from| match from {
                    LinkState::Idle => "finish called without a request",
                    LinkState::Requested => "finish called before reply",
                    LinkState::Tunnelling => "a tunnel has no finish; close it instead",
                    LinkState::Finished | LinkState::Streaming | LinkState::Replied => {
                        "finish called twice"
                    }
                })?;
            if from == LinkState::Streaming {
                push_haul(&mut state.outbox, request_id, true, &[])
                    .map_err(|_| "FIN frame could not be encoded")?;
            }
            Ok(())
        })?;
        rb_self.flush_to(ruby, io)
    }

    pub fn ready(ruby: &Ruby, rb_self: &Self, io: Value) -> Result<(), Error> {
        rb_self.try_with_state(ruby, |state| -> Result<(), &str> {
            let (request_id, _) = link::advance(&mut state.link, LinkEvent::Ready, |from| {
                if from == LinkState::Idle {
                    "ready called without a request"
                } else {
                    "ready called before finish"
                }
            })?;
            state.outbox.extend_from_slice(&encode_ready(request_id));
            Ok(())
        })?;
        rb_self.flush_to(ruby, io)
    }

    pub fn request_id(ruby: &Ruby, rb_self: &Self) -> Result<Option<u32>, Error> {
        rb_self.with_state(ruby, |state| link::request_id(&state.link))
    }

    fn with_state<T>(&self, ruby: &Ruby, f: impl FnOnce(&mut State) -> T) -> Result<T, Error> {
        let mut state = self
            .state
            .try_borrow_mut()
            .map_err(|_| protocol_error(ruby, "codec is busy in another thread"))?;
        Ok(f(&mut state))
    }

    fn try_with_state<T, E: Display>(
        &self,
        ruby: &Ruby,
        f: impl FnOnce(&mut State) -> Result<T, E>,
    ) -> Result<T, Error> {
        self.with_state(ruby, f)?.or_protocol_error(ruby)
    }

    fn flush_to(&self, ruby: &Ruby, io: Value) -> Result<(), Error> {
        let outbox = self.with_state(ruby, |state| std::mem::take(&mut state.outbox))?;
        if outbox.is_empty() {
            return Ok(());
        }
        let _: Value = io.funcall("write", (ruby.str_from_slice(&outbox),))?;
        Ok(())
    }

    fn read_body(&self, ruby: &Ruby, io: Value, hail: &Hail) -> Result<Value, Error> {
        ensure!(
            ruby,
            hail.content_length <= MAX_BODY,
            "request body of {} bytes exceeds the engine limit",
            hail.content_length
        );
        if hail.content_length == 0 {
            return null_input(ruby);
        }
        let expected = usize::try_from(hail.content_length)
            .map_err(|_| protocol_error(ruby, "request body does not fit in memory"))?;
        let mut sink = if hail.content_length > SPOOL_THRESHOLD {
            BodySink::Spool { file: spool_file(ruby)?, written: 0 }
        } else {
            BodySink::Memory(Vec::with_capacity(expected))
        };
        self.receive_body(ruby, io, hail, expected, &mut sink)?;
        sink.into_input(ruby)
    }

    fn receive_body(
        &self,
        ruby: &Ruby,
        io: Value,
        hail: &Hail,
        expected: usize,
        body: &mut BodySink,
    ) -> Result<(), Error> {
        loop {
            let payload = self
                .read_frame(ruby, io, MessageType::Haul)?
                .ok_or("Mothership closed the link mid-body")
                .or_protocol_error(ruby)?;
            let chunk = decode_haul(&payload).or_protocol_error(ruby)?;
            ensure!(
                ruby,
                chunk.request_id == hail.request_id,
                "HAUL for request {} while reading request {}",
                chunk.request_id,
                hail.request_id
            );
            ensure!(
                ruby,
                body.len() + chunk.data.len() <= expected,
                "request body longer than CONTENT_LENGTH"
            );
            body.push(ruby, chunk.data)?;
            if chunk.fin {
                break;
            }
        }

        ensure!(
            ruby,
            body.len() == expected,
            "request body ended after {} of {expected} bytes",
            body.len()
        );
        Ok(())
    }

    fn read_frame(
        &self,
        ruby: &Ruby,
        io: Value,
        expected: MessageType,
    ) -> Result<Option<Vec<u8>>, Error> {
        loop {
            if let Some((msg_type, payload)) =
                self.try_with_state(ruby, |state| take_frame(&mut state.inbox))?
            {
                ensure!(ruby, msg_type == expected, "Expected {expected:?}, got {msg_type:?}");
                return Ok(Some(payload));
            }

            let chunk = match io.funcall::<_, _, RString>("readpartial", (READ_CHUNK,)) {
                Ok(chunk) => chunk.to_bytes(),
                Err(error) if error.is_kind_of(ruby.exception_eof_error()) => {
                    let buffered = self.with_state(ruby, |state| state.inbox.len())?;
                    ensure!(
                        ruby,
                        buffered == 0,
                        "link closed with {buffered} bytes of a partial frame"
                    );
                    return Ok(None);
                }
                Err(error) => return Err(error),
            };
            self.with_state(ruby, |state| state.inbox.extend_from_slice(&chunk))?;
        }
    }
}

enum BodySink {
    Memory(Vec<u8>),
    Spool { file: Value, written: usize },
}

impl BodySink {
    const fn len(&self) -> usize {
        match self {
            Self::Memory(bytes) => bytes.len(),
            Self::Spool { written, .. } => *written,
        }
    }

    fn push(&mut self, ruby: &Ruby, data: &[u8]) -> Result<(), Error> {
        match self {
            Self::Memory(bytes) => bytes.extend_from_slice(data),
            Self::Spool { file, written } => {
                let _: Value = file.funcall("write", (ruby.str_from_slice(data),))?;
                *written += data.len();
            }
        }
        Ok(())
    }

    fn into_input(self, ruby: &Ruby) -> Result<Value, Error> {
        match self {
            Self::Memory(bytes) => string_io(ruby)?.funcall("new", (ruby.str_from_slice(&bytes),)),
            Self::Spool { file, .. } => {
                let _: Value = file.funcall("rewind", ())?;
                Ok(file)
            }
        }
    }
}

fn http_status(ruby: &Ruby, status: i64) -> Result<u16, Error> {
    u16::try_from(status).ok().filter(|status| (100..=599).contains(status)).ok_or_else(|| {
        Error::new(ruby.exception_arg_error(), format!("invalid HTTP status: {status}"))
    })
}

fn shares_value(name: &[u8], value: &[u8]) -> bool {
    SHARED_VALUES.contains(&name) || (name == b"QUERY_STRING" && value.is_empty())
}

/// Body chunk `index`: Rack bodies yield Strings, nothing else.
fn body_chunk(ruby: &Ruby, chunks: RArray, index: usize) -> Result<RString, Error> {
    let offset = isize::try_from(index)
        .map_err(|_| Error::new(ruby.exception_range_error(), "body array too long"))?;
    let chunk: Value = chunks.entry(offset)?;
    RString::from_value(chunk).ok_or_else(|| {
        Error::new(
            ruby.exception_type_error(),
            format!("body chunk must be a String, got {}", chunk.class().inspect()),
        )
    })
}

/// Move the link past its Reply and queue the Reply head; the request id is
/// what the body frames must carry.
fn push_reply(
    state: &mut State,
    event: LinkEvent,
    status: u16,
    headers: Vec<Pair>,
    body: ReplyBody,
) -> Result<u32, &'static str> {
    let (request_id, _) = link::advance(&mut state.link, event, |from| {
        if from == LinkState::Idle {
            "reply called without a request"
        } else {
            "reply already sent for this request"
        }
    })?;
    let frame = encode_reply(&Reply { request_id, status, headers, body })
        .map_err(|_| "reply head exceeds the frame size limit")?;
    state.outbox.extend_from_slice(&frame);
    Ok(request_id)
}

/// A streamed body is complete: the link waits for `ready`.
fn finish_stream(state: &mut State) -> Result<(), &'static str> {
    link::advance(&mut state.link, LinkEvent::Finish, |_| "finish called twice").map(drop)
}

fn push_body(
    outbox: &mut Vec<u8>,
    request_id: u32,
    data: &[u8],
    fin: bool,
) -> Result<(), ProtocolError> {
    let mut pieces = data.chunks(HAUL_CHUNK_LEN).peekable();
    while let Some(piece) = pieces.next() {
        push_haul(outbox, request_id, fin && pieces.peek().is_none(), piece)?;
    }
    Ok(())
}

fn take_frame(inbox: &mut Vec<u8>) -> Result<Option<(MessageType, Vec<u8>)>, String> {
    if inbox.len() < 5 {
        return Ok(None);
    }
    let (msg_type, len) = decode_header(inbox).map_err(|error| error.to_string())?;
    if len > MAX_FRAME_PAYLOAD {
        return Err(format!("{msg_type:?} frame of {len} bytes exceeds the frame size limit"));
    }
    if inbox.len() < 5 + len {
        return Ok(None);
    }
    let payload = inbox[5..5 + len].to_vec();
    inbox.drain(..5 + len);
    Ok(Some((msg_type, payload)))
}

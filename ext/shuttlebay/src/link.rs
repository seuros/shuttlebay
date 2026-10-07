use state_machines::state_machine;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct RequestId(u32);

state_machine! {
    name: Link,
    dynamic: true,
    initial: Idle,
    states: [
        Idle,
        superstate Exchange(RequestId) {
            state Requested,
            state Streaming,
            state Replied,
            state Tunnelling,
            state Finished,
            initial: Requested,
        },
    ],
    events {
        hail {
            transition: { from: Idle, to: Exchange }
        }
        reply_stream {
            transition: { from: Requested, to: Streaming }
        }
        reply_whole {
            transition: { from: Requested, to: Replied }
        }
        reply_tunnel {
            transition: { from: Requested, to: Tunnelling }
        }
        finish {
            transition: { from: [Streaming, Replied], to: Finished }
        }
        ready {
            transition: { from: Finished, to: Idle }
        }
    }
}

pub type Machine = DynamicLink<()>;

pub fn new() -> Machine {
    DynamicLink::new(())
}

pub fn request_id(link: &Machine) -> Option<u32> {
    link.exchange_data().map(|id| id.0)
}

pub fn begin(link: &mut Machine, request_id: u32) -> Result<(), &'static str> {
    link.handle(LinkEvent::Hail).map_err(|_| "read_request called before the previous ready")?;
    link.set_exchange_data(RequestId(request_id)).map_err(|_| "request id could not be recorded")
}

pub fn request_in(
    link: &Machine,
    wanted: LinkState,
    without_request: &'static str,
    elsewhere: &'static str,
) -> Result<u32, &'static str> {
    let request_id = request_id(link).ok_or(without_request)?;
    if link.current_state() == wanted { Ok(request_id) } else { Err(elsewhere) }
}

pub fn advance(
    link: &mut Machine,
    event: LinkEvent,
    refused: impl FnOnce(LinkState) -> &'static str,
) -> Result<(u32, LinkState), &'static str> {
    let from = link.current_state();
    let refusal = refused(from);
    let request_id = request_id(link).ok_or(refusal)?;
    link.handle(event).map_err(|_| refusal)?;
    Ok((request_id, from))
}

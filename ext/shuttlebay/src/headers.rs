use magnus::{Error, RArray, RHash, RString, Ruby, Value, prelude::*, r_hash::ForEach};
use mothership_docking_protocol::Pair;

pub fn flatten(ruby: &Ruby, headers: RHash) -> Result<Vec<Pair>, Error> {
    let mut pairs = Vec::with_capacity(headers.len());
    headers.foreach(|name: Value, value: Value| {
        let name = header_string(ruby, name, "header name")?.to_bytes().to_vec();
        if let Some(values) = RArray::from_value(value) {
            for index in 0..values.len() {
                let offset = isize::try_from(index).map_err(|_| {
                    Error::new(ruby.exception_range_error(), "header array too long")
                })?;
                let item = header_string(ruby, values.entry(offset)?, "header value")?;
                pairs.push((name.clone(), item.to_bytes().to_vec()));
            }
        } else {
            let value = header_string(ruby, value, "header value")?.to_bytes();
            for line in value.split(|byte| *byte == b'\n') {
                pairs.push((name.clone(), line.to_vec()));
            }
        }
        Ok(ForEach::Continue)
    })?;
    Ok(pairs)
}

fn header_string(ruby: &Ruby, value: Value, what: &str) -> Result<RString, Error> {
    RString::from_value(value).ok_or_else(|| {
        Error::new(
            ruby.exception_type_error(),
            format!("{what} must be a String, got {}", value.class().inspect()),
        )
    })
}

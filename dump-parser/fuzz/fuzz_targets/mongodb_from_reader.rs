#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let reader = std::io::BufReader::new(data);
    let _ = dump_parser::mongodb::Archive::from_reader(reader);
});

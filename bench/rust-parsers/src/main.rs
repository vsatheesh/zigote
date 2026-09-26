//! Count records and residues with several Rust FASTA parsers, for comparison
//! with `zigote --parse-only`.
//!
//! usage: rust-bench <parser> <file.fa>
//!
//! Each parser produces a contiguous sequence without line breaks, as zigote
//! does, using the library's buffer-reusing API where it has one. The one
//! exception is `seq_io-lines`, which only sums line lengths without joining
//! them; it is a zero-copy reference point, not a like-for-like comparison.
use std::env;
use std::fs::File;
use std::io::BufReader;
use std::process;

type Counts = (u64, u64);
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn needletail(path: &str) -> Result<Counts> {
    let mut reader = needletail::parse_fastx_file(path)?;
    let (mut records, mut residues) = (0, 0);
    while let Some(record) = reader.next() {
        let record = record?;
        records += 1;
        residues += record.seq().len() as u64;
    }
    Ok((records, residues))
}

fn seq_io_full(path: &str) -> Result<Counts> {
    let mut reader = seq_io::fasta::Reader::from_path(path)?;
    let (mut records, mut residues) = (0, 0);
    while let Some(record) = reader.next() {
        let record = record?;
        records += 1;
        residues += record.full_seq().len() as u64;
    }
    Ok((records, residues))
}

fn seq_io_lines(path: &str) -> Result<Counts> {
    let mut reader = seq_io::fasta::Reader::from_path(path)?;
    let (mut records, mut residues) = (0, 0);
    while let Some(record) = reader.next() {
        let record = record?;
        records += 1;
        residues += record.seq_lines().map(|line| line.len() as u64).sum::<u64>();
    }
    Ok((records, residues))
}

fn paraseq(path: &str) -> Result<Counts> {
    let mut reader = paraseq::fasta::Reader::new(File::open(path)?);
    let mut set = reader.new_record_set();
    let (mut records, mut residues) = (0, 0);
    while set.fill(&mut reader)? {
        for record in set.iter() {
            let record = record?;
            records += 1;
            residues += record.seq().len() as u64;
        }
    }
    Ok((records, residues))
}

fn noodles(path: &str) -> Result<Counts> {
    let mut reader = noodles_fasta::io::Reader::new(BufReader::new(File::open(path)?));
    let mut definition = String::new();
    let mut sequence = Vec::new();
    let (mut records, mut residues) = (0, 0);
    loop {
        definition.clear();
        if reader.read_definition(&mut definition)? == 0 {
            break;
        }
        sequence.clear();
        reader.read_sequence(&mut sequence)?;
        records += 1;
        residues += sequence.len() as u64;
    }
    Ok((records, residues))
}

fn rust_bio(path: &str) -> Result<Counts> {
    use bio::io::fasta::FastaRead;
    let mut reader = bio::io::fasta::Reader::from_file(path)?;
    let mut record = bio::io::fasta::Record::new();
    let (mut records, mut residues) = (0, 0);
    loop {
        reader.read(&mut record)?;
        if record.is_empty() {
            break;
        }
        records += 1;
        residues += record.seq().len() as u64;
    }
    Ok((records, residues))
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: rust-bench <needletail|seq_io|seq_io-lines|paraseq|noodles|rust-bio> <file.fa>");
        process::exit(2);
    }
    let path = args[2].as_str();
    let result = match args[1].as_str() {
        "needletail" => needletail(path),
        "seq_io" => seq_io_full(path),
        "seq_io-lines" => seq_io_lines(path),
        "paraseq" => paraseq(path),
        "noodles" => noodles(path),
        "rust-bio" => rust_bio(path),
        other => {
            eprintln!("unknown parser: {other}");
            process::exit(2);
        }
    };
    match result {
        Ok((records, residues)) => println!("{records} {residues}"),
        Err(err) => {
            eprintln!("{}: {err}", args[1]);
            process::exit(1);
        }
    }
}

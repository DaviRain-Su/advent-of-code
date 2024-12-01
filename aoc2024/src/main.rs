use clap::Parser;

pub mod day1;

#[derive(Parser, Debug)]
pub enum Args {
    #[clap(name = "day1")]
    Day1(day1::Day1),
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    match args {
        Args::Day1(day1) => day1.run(),
    }
}

use clap::Parser;

pub mod day1;
pub mod day2;

#[derive(Parser, Debug)]
pub enum Args {
    #[clap(name = "day1")]
    Day1(day1::Day1),
    #[clap(name = "day2")]
    Day2(day2::Day2),
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    match args {
        Args::Day1(day1) => day1.run(),
        Args::Day2(day2) => day2.run(),
    }
}

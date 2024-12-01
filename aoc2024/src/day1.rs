use clap::Parser;

#[derive(Parser, Debug)]
pub struct Day1 {}

impl Day1 {
    pub fn run(&self) -> anyhow::Result<()> {
        let input = read_input()?;
        let answer = self.solve(input);
        println!("Answer: {}", answer);
        Ok(())
    }

    pub fn solve(&self, input: Vec<(usize, usize)>) -> usize {
        let (mut nums1, mut nums2): (Vec<usize>, Vec<usize>) = input.iter().cloned().unzip();
        nums1.sort();
        nums2.sort();

        // compare absolute difference between each pair of numbers
        // return the sum of the differences
        // another way solve by using zip
        nums1
            .iter()
            .zip(nums2.iter())
            .map(|(a, b)| (*a as isize - *b as isize).abs() as usize)
            .sum()
    }
}

fn read_input() -> anyhow::Result<Vec<(usize, usize)>> {
    let input = include_str!("../../data/day1.txt");
    // parse string separated by \n and parse each line to usize by whitespace
    // return a tuple of (usize, usize)
    let split = input.split("\n").collect::<Vec<&str>>();
    let split = split
        .iter()
        .map(|s| s.split_whitespace())
        .map(|s| s.collect::<Vec<&str>>())
        .collect::<Vec<Vec<&str>>>();
    let split = split
        .iter()
        .map(|s| {
            s.iter()
                .map(|s| s.parse::<usize>().unwrap())
                .collect::<Vec<usize>>()
        })
        .collect::<Vec<Vec<usize>>>();
    let split = split
        .iter()
        .filter(|s| s.len() == 2)
        .map(|s| (s[0], s[1]))
        .collect::<Vec<(usize, usize)>>();

    Ok(split)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_read_input() {
        let _input = read_input().unwrap();
    }
}

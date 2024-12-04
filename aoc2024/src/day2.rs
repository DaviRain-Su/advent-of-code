use clap::Parser;

#[derive(Parser, Debug)]
pub struct Day2 {}

impl Day2 {
    pub fn run(&self) -> anyhow::Result<()> {
        let input = include_str!("../../data/day2.txt");
        let answer = self.solve(input);
        println!("Answer: {}", answer);
        Ok(())
    }

    pub fn solve(&self, input: &str) -> usize {
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
            .filter(|s| !s.is_empty())
            .collect::<Vec<Vec<usize>>>();

        split
            .into_iter()
            .filter(|v| {
                // 检查序列是否单调递增或单调递减
                let increasing = v.windows(2).all(|w| w[1] > w[0]);
                let decreasing = v.windows(2).all(|w| w[1] < w[0]);

                // 检查相邻数字之间的差值是否在1到3之间
                let valid_diff = v.windows(2).all(|w| {
                    let diff = if w[0] > w[1] {
                        w[0] - w[1]
                    } else {
                        w[1] - w[0]
                    };
                    diff >= 1 && diff <= 3
                });

                (increasing || decreasing) && valid_diff
            })
            .count()
    }
}

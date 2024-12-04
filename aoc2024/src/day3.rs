use clap::Parser;
use regex::Regex;

#[derive(Parser, Debug)]
pub struct Day3 {}

impl Day3 {
    pub fn run(&self) -> anyhow::Result<()> {
        let input = include_str!("../../data/day3.txt");
        let result = solve(&input);
        println!("Answer: {}", result);
        Ok(())
    }
}

fn solve(input: &str) -> u32 {
    // 创建正则表达式来匹配有效的mul指令
    // 匹配 mul( 后跟1-3位数字, 再跟1-3位数字 )
    let re = Regex::new(r"mul\((\d{1,3}),(\d{1,3})\)").unwrap();

    // 找出所有匹配项并计算结果之和
    re.captures_iter(input)
        .map(|cap| {
            // 提取两个数字并转换为u32
            let x: u32 = cap[1].parse().unwrap();
            let y: u32 = cap[2].parse().unwrap();
            x * y
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_example() {
        let input = "xmul(2,4)%&mul[3,7]!@^do_not_mul(5,5)+mul(32,64]then(mul(11,8)mul(8,5))";
        assert_eq!(solve(input), 161);
    }
}

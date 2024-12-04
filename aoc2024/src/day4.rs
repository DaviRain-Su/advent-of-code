use clap::Parser;

#[derive(Parser, Debug)]
pub struct Day4 {}

impl Day4 {
    pub fn run(&self) -> anyhow::Result<()> {
        let input = include_str!("../../data/day4.txt");
        let result = solve(input);
        println!("Answer: {}", result);
        Ok(())
    }
}

fn solve(input: &str) -> u32 {
    // 将输入转换为字符矩阵
    let grid: Vec<Vec<char>> = input.lines().map(|line| line.chars().collect()).collect();

    let height = grid.len();
    let width = grid[0].len();
    let mut count = 0;

    // 定义8个搜索方向：右、左、下、上、右下、左下、右上、左上
    let directions = [
        (0, 1),   // 右
        (0, -1),  // 左
        (1, 0),   // 下
        (-1, 0),  // 上
        (1, 1),   // 右下
        (1, -1),  // 左下
        (-1, 1),  // 右上
        (-1, -1), // 左上
    ];

    // 遍历矩阵中的每个位置
    for i in 0..height {
        for j in 0..width {
            // 从每个位置开始，向8个方向搜索
            for &(di, dj) in &directions {
                // 检查从当前位置开始是否能形成 "XMAS"
                if check_word(&grid, i, j, di, dj, height, width) {
                    count += 1;
                }
            }
        }
    }

    count
}

fn check_word(
    grid: &[Vec<char>],
    start_i: usize,
    start_j: usize,
    di: i32,
    dj: i32,
    height: usize,
    width: usize,
) -> bool {
    // 目标单词
    let target = ['X', 'M', 'A', 'S'];

    // 检查是否是起始字符 'X'
    if grid[start_i][start_j] != 'X' {
        return false;
    }

    // 检查接下来的三个字符是否匹配 'M', 'A', 'S'
    for k in 1..4 {
        let new_i = start_i as i32 + di * k;
        let new_j = start_j as i32 + dj * k;

        // 检查边界
        if new_i < 0 || new_i >= height as i32 || new_j < 0 || new_j >= width as i32 {
            return false;
        }

        // 检查字符是否匹配
        if grid[new_i as usize][new_j as usize] != target[k as usize] {
            return false;
        }
    }

    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_day4() {
        let input = "\
MMMSXXMASM
MSAMXMSMSA
AMXSXMAAMM
MSAMASMSMX
XMASAMXAMM
XXAMMXXAMA
SMSMSASXSS
SAXAMASAAA
MAMMMXMMMM
MXMXAXMASX";

        assert_eq!(solve(input), 18);
    }
}

# Coding style

- C/C++ 遵循 Google C++ Style Guide 中适用于该语言的规则；Python 遵循
  Google Python Style Guide。配置见 `.clang-format`、`CPPLINT.cfg`、
  `ruff.toml`，不对 `vendor/` 应用本仓库风格。
- C/C++ 使用 clang-format 和 cpplint；Python 使用 Ruff 格式化和 lint，
  80 列、双引号；不强制 docstring，已有 docstring 按 Google 风格检查。
  Ruff 只覆盖部分 Google 规则，其余靠审查。
- 首次开发运行 `scripts/coding_style/install-hooks`。提交前运行
  `scripts/coding_style/check --staged`；检查只报错，不修改文件或暂存区。
- 可显式运行 `scripts/coding_style/fix <file.py> ...` 应用 Ruff 安全修复，
  剩余 lint 按诊断手动修复；需要格式化时显式运行
  `scripts/coding_style/format <file> ...`，检查 diff 后重新暂存。
- 不要顺手格式化与任务无关的文件；部分暂存时尤其要保留用户未暂存的改动。

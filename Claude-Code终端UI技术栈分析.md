# Claude Code 终端 UI 技术栈分析

> 分析版本：Claude Code 2.1.63
> 分析日期：2026-03-20
> 源码位置：`~/.nvm/versions/node/v24.13.1/lib/node_modules/@anthropic-ai/claude-code/`

## 概述

Claude Code 是 Anthropic 官方的 CLI 编程助手工具。其终端 UI 并非传统的 `printf` + ANSI 转义码方案，而是基于 **React + Ink** 构建的完整终端 React 应用。

## 核心技术栈

### 1. Ink（终端 React 渲染器）

- 官方仓库：[vadimdemedes/ink](https://github.com/vadimdemedes/ink)
- 作用：将 React 组件渲染到终端，类似 React Native 之于移动端
- Claude Code 中使用的 Ink 组件：
  - `ink` — 核心渲染引擎
  - `ink-box` — 带边框的容器组件
  - `ink-text` — 文本渲染组件
  - `ink-link` — 终端超链接
  - `ink-progress` — 进度条组件
  - `ink-virtual-text` — 虚拟文本渲染

### 2. React

- 完整的 React 运行时，支持：
  - `react.element` — JSX 元素
  - `react.memo` — 性能优化
  - `react.suspense` — 异步加载
  - `react.context` — 状态共享
  - `react.forward_ref` — ref 转发
  - `react.fragment` — 片段
  - `react.lazy` — 懒加载

### 3. Yoga Layout

- Facebook 开源的跨平台 Flexbox 布局引擎
- Ink 底层使用 Yoga 计算终端中的组件布局
- 支持 `flexDirection`、`padding`、`margin`、`alignItems` 等 CSS Flexbox 属性
- 实现终端内容的自适应宽度和对齐

## 架构特点

```
┌─────────────────────────────────────────────┐
│              React Components               │
│  (Box, Text, Spinner, ProgressBar, etc.)    │
├─────────────────────────────────────────────┤
│              Ink Renderer                   │
│  (React reconciler for terminal)            │
├─────────────────────────────────────────────┤
│              Yoga Layout                    │
│  (Flexbox engine for layout calculation)    │
├─────────────────────────────────────────────┤
│              ANSI Terminal Output            │
│  (Colors, cursor control, screen buffer)    │
└─────────────────────────────────────────────┘
```

### 渲染流程

1. 开发者用 JSX 编写终端 UI 组件
2. React 处理组件树和状态更新
3. Ink 将 React 虚拟 DOM 转换为终端输出指令
4. Yoga 计算每个组件在终端中的位置和尺寸
5. 最终输出 ANSI 转义序列到终端

### 关键能力

| 能力 | 实现方式 |
|------|---------|
| 自适应宽度 | Yoga Flexbox 布局 |
| 边框/Box | `ink-box` 组件 + Unicode 字符 |
| 颜色/样式 | ANSI 256色/真彩色 |
| Spinner 动画 | React state + setInterval |
| 进度条 | `ink-progress` 组件 |
| 超链接 | `ink-link`（OSC 8 终端超链接协议）|
| 交互式输入 | Ink 内置 `useInput` hook |
| 实时更新 | React 状态驱动重渲染 |

## 打包方式

- 所有依赖打包为单个 `cli.js`（约 12MB）
- 使用 ESM 模块格式
- 代码经过 minify 混淆处理
- 附带 `resvg.wasm`（SVG 渲染）和 `tree-sitter.wasm`（代码解析）

## 对 Bash 脚本的启示

Claude Code 的方案是 Node.js 生态专属的，不适合直接用于 bash 脚本。
对于 bash 脚本的终端美化，推荐以下替代方案：

| 方案 | 说明 | 适用场景 |
|------|------|---------|
| [gum](https://github.com/charmbracelet/gum) | Go 编写的终端 UI 工具，专为 shell 脚本设计 | 交互式菜单、表格、边框、spinner |
| [fzf](https://github.com/junegunn/fzf) | 模糊搜索选择器 | 列表选择 |
| [rich-cli](https://github.com/Textualize/rich-cli) | Python 终端美化 | 表格、Markdown 渲染 |
| 纯 ANSI | `\033[38;5;Xm` 256色 + Unicode 边框字符 | 零依赖场景 |

# YQE-134 工程汇报设计输入

## 任务本质

这不是状态 dashboard，也不是 Linear 字段汇总。页面要帮助 workflow owner 判断一个表面为 Done 的 root issue 是否已经可信交付。真正的阅读难点是三层语义互相冲突：implementation agent 自报完成，final review 记录目标实现代码中未检出三个函数定义且目标渲染点仍输出纯文本，而 root 和 review issue 最终都显示 Done。

## 读者和场景

主要读者是 Symphony workflow owner。主要场景是在笔记本上打开本地 HTML，在 1 到 3 分钟内决定是否需要返工、依据是什么、下一步由谁执行。窄屏用于快速复核，不要求把全部证据压进首屏。

## 三版共同事实

三版只能使用 `report_context.json`。必须同时出现 YQE-134、YQE-142、YQE-143，并准确表达：root 的表面状态是 Done；implementation 自报 completed；final review 的 outcome 是 fail / needs_rework；审查在目标实现代码中未检出 issue_link/2、issue_url/2、extract_team_domain/1 三个函数定义，且目标渲染点仍输出纯文本；测试中存在 issue_link/2 调用/引用，但审查指出该函数未定义；root 在审查后发生状态往返。

## 三版共同判断

当前不能把 YQE-134 视为可信完成。推荐动作是恢复 active / needs_rework，重新实现或提交反证，重新运行测试并进行独立审查。页面不能把“review issue 已 Done”误写成“review 已通过”。

## 输出形式

输出是可双击打开的单文件 HTML。桌面基准视口为 1440 x 900，窄屏基准视口为 390 x 844。CSS 和必要 JS 内嵌，不加载远程字体、脚本、样式或图片。证据链接可以使用普通 `<a href>` 指向 Linear，但不得用远程资源参与页面渲染。

## 图片判断

图片不是内容必需资产。本案例的主要材料是状态冲突、审查证据和动作，不使用 stock 图、logo、装饰性插画或手绘 SVG。视觉母题必须来自事实关系和阅读任务。

## 可读性下限

正文不小于 14px，标签和注释不小于 12px，正文对比度至少 4.5:1。首屏必须给出当前判断、表面状态为什么不可信、最关键证据和所需动作。长评论、原始 JSON 和长证据默认折叠。任何关键结论附近都要说明证据证明了什么。

## 三个叙事角色

1. `case-brief`：像案件卷宗一样组织情况、冲突、判定、证据链和处置。
2. `decision-memo`：围绕“能否接受完成”这一决定组织选项、判据、推理和建议。
3. `review-narrative`：findings first，组织严重性、主张、反证、影响和重新通过条件。

## 禁止项

不使用 dashboard 作为默认构图，不做 KPI 卡片阵列，不把三版做成同一骨架换肤，不编造统计数字，不用 emoji 充当图标，不使用紫蓝渐变和通用霓虹，不让矩阵或时间线取代结论。

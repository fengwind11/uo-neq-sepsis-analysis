# PASS_SOURCE_ONLY_NO_REMODEL

## 裁决

`research_vasopressor_restart_eicu_v1.e05_sepsis_cohort` 的原始创建 SQL、中心依赖和升压药归一化依赖已从最初 `vasopressor_restart_eicu_v1` 项目中恢复，并完成隔离临时重建。

- 当前持久表：11,649 rows / 11,649 unique `patientunitstayid`。
- 原逻辑临时重建：11,649 rows / 11,649 unique `patientunitstayid`。
- 成员交集：11,649；current-only=0；rebuilt-only=0。
- 全部 29 个 e05 字段不一致：0。
- 当前及重建表重复键：均为 0。
- 1,961 名 ratio cohort 成员全部存在于当前和重建 e05。
- 生理 clean cohort：1,816；其中 13 名 28-day in-hospital outcome 缺失。
- 正式 v1.1 eICU model cohort：1,803；deaths=528；全部存在于当前和重建 e05。

因此，本轮只完成来源闭环，不重跑任何模型；`CORRECTED_MANUSCRIPT_RESULTS_v1_1.zip` 内全部冻结估计继续保留。本裁决不等同于新的投稿批准，也不把效应显著性作为放行依据。

## 原始来源与哈希

- 输入结果包 SHA-256：`2107ee88e6dd52f5c9eb6893cc46285cf3281470928aae84ba5e87206458d1eb`。
- 原 e05 SQL SHA-256：`e07bc97255c94b7336ddc5094b5ba591dc78d8e6e690d977034cd2d2c8bb3506`；与原 Extraction Package v1.0 的 `SHA256SUMS.txt` 一致。
- 原 e06 SQL SHA-256：`e7f0a79b4fab9e64645198e6a4ef826868ee8cbd7ec55ad81fb0a9fae6942593`；与原清单一致。
- 原 schema/function bootstrap SQL SHA-256：`f209a38d681156439d8417fd3386d27ee5a6a29f656e4fcda72f631d080babed`；与原 Stage 1 清单一致。
- 原 s16 center audit SQL SHA-256：`fbb007202af6aaa672c9ad3e4854e69a1de21884b358c3737ce04e7f0f984e69`；原目录没有提供独立清单，本值为本轮现场计算值。

## 重建边界

原始数据库表仅被读取。PostgreSQL 不允许在 `READ ONLY` transaction 中执行 temp CTAS，因此重建在单会话 `pg_temp` 中执行，脚本静态检查确认没有持久 schema 的写入语句，并以 `ROLLBACK` 结束。患者级成员键和差异文件仅保留于本地 `PRIVATE_WORK/FINAL_SOURCE_CLOSURE_20261001`，未进入本公开包。

## 时间解释

本研究采用 encounter-level sepsis + pressor-first landmark。e05 没有要求感染证据位于 T0 前；ratio cohort 中 793/1,961 的最早感染证据 offset 晚于 T0，此项只作时间语义披露，不改变冻结队列。11,649 是上游 e05 总数，不是正式分析目标样本数。

## 剩余限制

e05 的 modified SOFA 是 first-day severity construct。只有 platelet 与 vasopressor 分量在 SQL 中明确限定为 ICU offset 0–1,440 min；`apacheapsvar` 提供的其余分量不能证明全部位于 pressor-first T0 前。因此 S8 继续标注为“SOFA component timing not fully verified”的补充严重度分析。

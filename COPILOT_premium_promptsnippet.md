## 新規機能追加用
最初に簡単な実装プランとタスク分解を作ってから実装してください。
不明点は既存設計・周辺実装・テスト方針を根拠に安全側で仮定して進め、API/仕様変更や大きく方針が分かれる場合のみ確認してください。
実装後は関連テストやlint/buildを実行し、失敗時は1回だけ自律的に再調査・再試行してください。
最後に、実装内容・仮定・未完了項目・次の作業候補を要約してください。

## 新規機能追加用(英語)
Start by making a brief implementation plan and task breakdown, then implement it.
If something is unclear, infer from the existing design, surrounding code, and test patterns, and proceed with the safest assumption. Only ask for confirmation if the change would affect public APIs, external behavior, or there are major design branches.
After implementation, run relevant tests and lint/build checks. If something fails, investigate and retry once autonomously.
At the end, summarize what was implemented, the assumptions made, any unfinished items, and the next recommended steps.


## バグ修正用
最初に簡単な原因仮説と修正方針を立ててから実装してください。
不明点は既存コード・テスト・ログを根拠に安全側で仮定して進め、API/仕様変更や破壊的変更がある場合のみ確認してください。
テスト失敗時は他の関連確認を続けたうえで、失敗箇所を1回だけ自律的に再調査・再試行してください。
解決しない場合のみ要点をまとめて停止し、最後に原因・修正内容・未解決事項を要約してください。

## バグ修正用(英語)
Start by making a brief root-cause hypothesis and fix plan, then implement it.
If something is unclear, infer from the existing code, tests, and logs, and proceed with the safest assumption. Only ask for confirmation if the change would affect public APIs, external behavior, or involve destructive changes.
If tests fail, continue with other relevant checks first, then investigate and retry the failed part once autonomously.
If it still cannot be resolved, stop and summarize the issue, what you tried, and any remaining open points.
At the end, summarize the root cause, the fix, and any unresolved items.


## リファクタ用
最初に簡単な作業プランを立ててから実装してください。
振る舞いは変えず、既存テスト・型・インターフェースとの整合を優先して進めてください。
方針が分かれる場合は、最小変更かつ安全な案を選び、API/仕様変更や破壊的変更がある場合のみ確認してください。
最後に、変更方針・影響範囲・変更ファイル・注意点を要約してください。

## リファクタ用(英語)
Start by making a brief plan, then implement it.
Preserve behavior, and prioritize consistency with existing tests, types, and interfaces.
If there are multiple possible directions, choose the smallest and safest change. Only ask for confirmation if the change would affect public APIs, external behavior, or involve destructive changes.
At the end, summarize the refactoring approach, impact scope, changed files, and any cautions.


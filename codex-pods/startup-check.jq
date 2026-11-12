# A claimed success in prose is insufficient: require an actual shell-tool
# completion with exit 0 and the expected stdout marker in Codex's JSONL events.
any(.[];
  .type == "item.completed"
  and .item.type == "command_execution"
  and .item.exit_code == 0
  and ((.item.aggregated_output // "") | contains("CODEX_POD_TOOL_OK"))
)

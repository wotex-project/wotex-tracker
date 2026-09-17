UPDATE records SET kind = 'rules'
WHERE kind = 'state' AND EXISTS (
  SELECT 1 FROM rule_states AS s
  WHERE s.scope = records.scope AND s.kind || ':' || s.rule_id = records.id
);
PRAGMA user_version = 4;

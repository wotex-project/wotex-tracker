UPDATE records SET document = json_set(document, '$.public.thing_id', (
  SELECT json_extract(p.document, '$.public.thing_id') FROM records AS p
  WHERE p.scope = records.scope AND p.kind = 'policies'
    AND p.id = json_extract(records.document, '$.public.rule.id')
    AND p.document != 'null'
    AND json_extract(p.document, '$.public.kind') = json_extract(records.document, '$.public.rule.kind')
  LIMIT 1
))
WHERE kind = 'alerts';
PRAGMA user_version = 7;

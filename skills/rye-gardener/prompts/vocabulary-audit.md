# Vocabulary audit prompt

Audit Rye vocabulary without writing.

1. Read `rye.type_vocabulary_report` for all three kinds.
2. Use usage count and first/last seen dates to prioritize suspicious values.
3. Compare spelling, token overlap, plugin/domain conventions, and examples of
   rows using each value.
4. Separate likely aliases from intentionally distinct concepts.
5. For every proposed alias, show the exact registry key and canonical value.
6. Identify possible duplicate nodes only when identity evidence exists beyond
   name similarity.
7. Do not call `record_assertion`, `create_knowledge_candidate`, or
   `merge_nodes` in this audit.

End with a review table: finding, evidence, risk, proposed action, reviewer
question.

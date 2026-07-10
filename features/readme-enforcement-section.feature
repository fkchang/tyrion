Feature: README enforcement section
  The README predates the enforcement layer (gate-refusal at close, claim-gate
  hook, import criteria lint, completed_by provenance) and does not mention it.
  Document it for developers evaluating tyrion from the README.

# RIGOR: build
Scenario: readme-enforcement-docs
  As a developer evaluating tyrion from the README
  In order to learn that protocol rules are mechanically enforced rather than skill prose
  I want a README section documenting the enforcement mechanisms

  Given the shipped enforcement features
  When I read README.md
  Then README.md contains an Enforcement section naming gate-refusal on close, the claim-gate hook, and import criteria lint
  And the section states that tyrion done --force records a force-close gate note
  And the section links to docs/dogfood-2026-07-10-dark-factory-first-run.md

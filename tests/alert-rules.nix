# The example's Grafana alert rules, examples/assets/grafana-alerting.yaml,
# as Prometheus rules in promtool. Each rule is its query A compared with
# its threshold C, held for its "for", as Grafana evaluates it:
#
# - promtool check rules parses every rule's query;
# - promtool test rules runs tests/alert-rules-test.yaml against them, with
#   the rule's uid as the alert name.
#
# A rule of another shape than query A and threshold C fails the
# conversion, and with it the check; extend the conversion for it.
{ runCommand, yq-go, jq, prometheus }:

runCommand "alert-rules" { nativeBuildInputs = [ yq-go jq prometheus.cli ]; } ''
  set -euo pipefail
  yq -o json ${../examples/assets/grafana-alerting.yaml} | jq '
    {groups: [.groups[] | {name, rules: [.rules[] | . as $rule
      | ([$rule.data[] | select(.refId == "A")] | if length == 1 then .[0].model.expr
          else error("\($rule.uid): no query A") end) as $expr
      | ([$rule.data[] | select(.refId == $rule.condition and .model.type == "threshold" and .model.expression == "A")]
          | if length == 1 then .[0].model.conditions[0].evaluator
            else error("\($rule.uid): its condition is not a threshold on A") end) as $evaluator
      | {
          alert: $rule.uid,
          expr: "(\($expr)) \({gt: ">", lt: "<"}[$evaluator.type] // error("\($rule.uid): evaluator \($evaluator.type)")) \($evaluator.params[0])",
          for: $rule.for,
          labels: $rule.labels
        }]}]}' > rules.json
  promtool check rules rules.json
  cp ${./alert-rules-test.yaml} test.yaml
  promtool test rules test.yaml
  cp rules.json $out
''

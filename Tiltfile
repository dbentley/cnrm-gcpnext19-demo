config = "a1"

data = decode_json(str(local('bazel build //example/kubernetes:%(config)s  && cat bazel-bin/example/kubernetes/%(config)s-tilt.json' % {'config': config})))

print('json data from bazel: %s' % data)

for img in data['images']:
  target = img['target']
  if target.startswith('//'):
    target = target[2:]
  custom_build(
    img['ref'],
    'bazel run %(target)s -- --norun && docker tag bazel/%(target)s $EXPECTED_REF' % {'target': target},
    img['deps'],
    )


for k8s in data['k8s']:
  for dep in k8s['deps']:
    watch_file(dep)
  k8s_data = local('bazel run %(target)s' % {'target': k8s['target']})
  # print('yaml data from bazel: %s' % k8s_data)
  k8s_yaml(k8s_data)

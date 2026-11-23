#!/usr/bin/env bash
set -euo pipefail

probe_dir=$(mktemp -d "$RUNNER_TEMP/gradle-graph-parity.XXXXXX")
mkdir -p "$probe_dir"/{empty-maven,gradle-home}
export GRADLE_OPTS="-Dmaven.repo.local=$probe_dir/empty-maven"
export NX_DAEMON=false NX_CACHE_PROJECT_GRAPH=false NX_NO_CLOUD=true
export GRADLE_PROBE_ARGS="$probe_dir/gradle-args"
node --version
java -version
"$JAVA17_HOME/bin/java" -version
node -p "'@nx/gradle ' + require('@nx/gradle/package.json').version"

mv gradlew .gradlew-cache-pilot
trap 'mv -f .gradlew-cache-pilot gradlew' EXIT
cat >gradlew <<'GRADLE_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$GRADLE_PROBE_ARGS"
if [[ "${GRADLE_PROBE_NETWORK:-}" != blocked ]]; then
  exec "$PWD/.gradlew-cache-pilot" "$@"
fi
exec sudo -n unshare --net --fork --kill-child=TERM bash -c '
  set -eu
  ip link set lo up
  test -z "$(ip -4 route show default)"
  test -z "$(ip -6 route show default)"
  exec "$@"
' bash runuser -u "$USER" -- env \
  "PATH=$PATH" "CI=$CI" "JAVA_HOME=$JAVA_HOME" "JAVA17_HOME=$JAVA17_HOME" \
  "GRADLE_USER_HOME=$GRADLE_USER_HOME" "GRADLE_OPTS=$GRADLE_OPTS" \
  "$PWD/.gradlew-cache-pilot" "$@"
GRADLE_WRAPPER
chmod +x gradlew

clear_gradle_outputs() {
  rm -rf -- .gradle build/nx \
    packages/gradle/batch-runner/{.gradle,build/nx} \
    packages/gradle/project-graph/{.gradle,build/nx}
}

monotonic_ms() {
  python3 -c 'import time; print(time.monotonic_ns() // 1_000_000)'
}

measure() {
  local label="$1"
  shift
  local start
  start=$(monotonic_ms)
  "$@"
  echo "$label: $(( $(monotonic_ms) - start )) ms" | tee -a "$GITHUB_STEP_SUMMARY"
}

graph() {
  local arm="$1" gradle_home="$2" network="$3"
  clear_gradle_outputs
  : > "$GRADLE_PROBE_ARGS"
  GRADLE_USER_HOME="$gradle_home" GRADLE_PROBE_NETWORK="$network" \
    NX_WORKSPACE_DATA_DIRECTORY="$probe_dir/$arm-nx" \
    measure "$arm Nx graph" timeout -k 15s 6m pnpm exec nx graph --file="$probe_dir/$arm.json"
  for required_arg in nxProjectGraph -PtargetNamePrefix=gradle: -PciTestTargetName=test-ci -PtestTargetName=test; do
    grep -Fx -- "$required_arg" "$GRADLE_PROBE_ARGS"
  done
  test -s "$probe_dir/$arm-nx/gradle-nodes.hash"
}

graph online "$probe_dir/gradle-home" normal
GRADLE_USER_HOME="$probe_dir/gradle-home" ./.gradlew-cache-pilot --stop
for daemon_log in "$probe_dir/gradle-home"/daemon/*/daemon-*.out.log; do
  [[ -f "$daemon_log" ]] || continue
  daemon_pid=${daemon_log##*/daemon-}
  daemon_pid=${daemon_pid%.out.log}
  deadline=$((SECONDS + 15))
  while daemon_state=$(ps -o stat= -p "$daemon_pid") && [[ "$daemon_state" != Z* ]]; do
    if ((SECONDS >= deadline)); then
      printf 'Gradle daemon %s did not exit before the cache snapshot.\n' "$daemon_pid" >&2
      exit 1
    fi
    sleep 0.2
  done
done
measure 'Pack dependency and wrapper caches' tar --zstd \
  --exclude='*.lock' --exclude='*.lck' --exclude=gc.properties \
  -C "$probe_dir/gradle-home" -cf "$probe_dir/gradle.tar.zst" caches/modules-2 wrapper/dists
wc -c "$probe_dir/gradle.tar.zst" | tee -a "$GITHUB_STEP_SUMMARY"
mv "$probe_dir/gradle-home" "$probe_dir/online-gradle-home"
mkdir "$probe_dir/gradle-home"
measure 'Extract dependency and wrapper caches' tar --zstd \
  -C "$probe_dir/gradle-home" -xf "$probe_dir/gradle.tar.zst"

graph restored "$probe_dir/gradle-home" blocked

node - "$probe_dir" <<'COMPARE' | tee -a "$GITHUB_STEP_SUMMARY"
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const directory = process.argv[2];
const load = (file) => JSON.parse(readFileSync(join(directory, file), 'utf8'));
const roots = ['.', 'packages/gradle/batch-runner', 'packages/gradle/project-graph'];
const edgeKey = ({ source, target, sourceFile = '', type = '' }) =>
  [source, target, sourceFile, type].join('\n');
const sortedEdges = (edges) =>
  [...edges].sort((left, right) => edgeKey(left).localeCompare(edgeKey(right)));

const compareJson = (left, right) =>
  JSON.stringify(left).localeCompare(JSON.stringify(right));

function normalizeGradleTargets(targets) {
  return Object.fromEntries(
    Object.entries(targets).map(([name, target]) => {
      if (!name.startsWith('gradle:')) {
        return [name, target];
      }
      const normalized = { ...target };
      if (target.dependsOn) {
        normalized.dependsOn = target.dependsOn
          .map((dependency) =>
            Array.isArray(dependency?.projects)
              ? { ...dependency, projects: [...dependency.projects].sort() }
              : dependency
          )
          .sort(compareJson);
      }
      if (target.inputs) {
        const isDependencyOutput = (input) =>
          input !== null && typeof input === 'object' && 'dependentTasksOutputFiles' in input;
        const outputInputs = target.inputs.filter(isDependencyOutput).sort(compareJson);
        normalized.inputs = target.inputs.map((input) =>
          isDependencyOutput(input) ? outputInputs.shift() : input
        );
      }
      return [name, normalized];
    })
  );
}

function readArm(arm) {
  const report = load(`${arm}-nx/gradle-nodes.hash`);
  const { graph } = load(`${arm}.json`);
  assert.deepStrictEqual(Object.keys(report.nodes).sort(), roots);
  for (const root of roots.slice(1)) {
    const { targets } = report.nodes[root];
    assert.ok(targets['gradle:test-ci'], `${arm} lacks gradle:test-ci in ${root}`);
    assert.ok(
      Object.keys(targets).some((target) => target.startsWith('gradle:test-ci--')),
      `${arm} lacks atomized Gradle test targets in ${root}`
    );
  }
  for (const jar of ['junit-jupiter-api', 'junit-jupiter-engine', 'kotlin-test']) {
    assert.ok(
      Object.keys(report.externalNodes).some((node) => node.startsWith(`gradle:${jar}-`)),
      `${arm} lacks Gradle external nodes for ${jar}`
    );
  }
  const graphNodes = Object.fromEntries(
    Object.entries(graph.nodes).filter(([, node]) => roots.includes(node.data.root))
  );
  assert.equal(Object.keys(graphNodes).length, roots.length);
  for (const { data } of Object.values(graphNodes)) {
    if (data.root !== '.') {
      assert.ok(data.targets['gradle:test-ci'], `${arm} final graph lacks Gradle test targets`);
    }
  }
  return {
    report: {
      ...report,
      buildFiles: [...report.buildFiles].sort(),
      dependencies: sortedEdges(report.dependencies),
      nodes: Object.fromEntries(
        Object.entries(report.nodes).map(([root, node]) => [
          root,
          { ...node, targets: normalizeGradleTargets(node.targets) }
        ])
      )
    },
    graphNodes: Object.fromEntries(
      Object.entries(graphNodes).map(([name, node]) => [
        name,
        { ...node, data: { ...node.data, targets: normalizeGradleTargets(node.data.targets) } }
      ])
    ),
    graphDependencies: Object.fromEntries(
      Object.keys(graphNodes).map((name) => [name, sortedEdges(graph.dependencies[name] ?? [])])
    )
  };
}

const online = readArm('online');
const restored = readArm('restored');
assert.deepStrictEqual(restored.report, online.report, 'Gradle reports differ');
assert.deepStrictEqual(restored.graphNodes, online.graphNodes, 'Nx Gradle projects differ');
assert.deepStrictEqual(restored.graphDependencies, online.graphDependencies, 'Nx Gradle edges differ');
const testTargetCount = Object.values(restored.report.nodes)
  .flatMap(({ targets }) => Object.keys(targets))
  .filter((target) => target.startsWith('gradle:test-ci--')).length;
console.log(
  `Matching Gradle reports and Nx projects: ${roots.length} projects, ` +
  `${testTargetCount} atomized test targets, ` +
  `${Object.keys(restored.report.externalNodes).length} external nodes`
);
COMPARE

import json
import os
import sys


def escape_annotation(value: str) -> str:
    return value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def emit(level: str, title: str, message: str) -> None:
    print(f"::{level} title={escape_annotation(title)}::{escape_annotation(message)}")


def main() -> int:
    root = os.environ.get('STATUS_ROOT', 'all-artifacts')
    summary_path = os.environ['GITHUB_STEP_SUMMARY']

    rows = []
    counts = {'clean': 0, 'warning': 0, 'failure': 0}

    if os.path.isdir(root):
        for current_root, _dirs, files in os.walk(root):
            if 'module-status.json' not in files:
                continue

            path = os.path.join(current_root, 'module-status.json')
            with open(path, 'r', encoding='utf-8') as handle:
                row = json.load(handle)

            rows.append(row)
            counts[row['class']] = counts.get(row['class'], 0) + 1

    rows.sort(key=lambda item: item['id'])
    warning_rows = [row for row in rows if row['class'] == 'warning']
    failure_rows = [row for row in rows if row['class'] == 'failure']

    with open(summary_path, 'a', encoding='utf-8') as summary:
        summary.write('# Compatibility Run Summary\n\n')
        summary.write('| Module | Class | State | Metadata | Dependency | Documentation |\n')
        summary.write('|---|---|---|---|---|---|\n')
        for row in rows:
            summary.write(
                f"| {row['id']} | {row['class']} | {row['compatibility_state']} | {row['metadata_status']} | {row['dependency_status']} | {row.get('documentation_status', 'unknown')} |\n"
            )

        summary.write('\n')
        summary.write(
            f"**Totals:** clean={counts.get('clean', 0)}, warning={counts.get('warning', 0)}, failure={counts.get('failure', 0)}\n"
        )

        if warning_rows:
            summary.write('\n## Warnings\n\n')
            for row in warning_rows:
                summary.write(f"- {row['id']}: {row['message']}\n")

        if failure_rows:
            summary.write('\n## Failures\n\n')
            for row in failure_rows:
                summary.write(f"- {row['id']}: {row['message']}\n")

    if warning_rows:
        print('Warnings detected:')
        for row in warning_rows:
            print(f"- {row['id']}: {row['message']}")
            emit('warning', row['id'], row['message'])

    if failure_rows:
        print('Failures detected:')
        for row in failure_rows:
            print(f"- {row['id']}: {row['message']}")
            emit('error', row['id'], row['message'])

    if counts.get('warning', 0) > 0:
        emit(
            'warning',
            'Compatibility summary',
            f"{counts['warning']} module(s) with warnings; {counts.get('clean', 0)} clean; {counts.get('failure', 0)} failed.",
        )

    if counts.get('failure', 0) > 0:
        emit(
            'error',
            'Compatibility summary',
            f"{counts['failure']} module(s) failed; {counts.get('warning', 0)} warning; {counts.get('clean', 0)} clean.",
        )
        return 1

    emit('notice', 'Compatibility summary', f"All failing modules cleared. clean={counts.get('clean', 0)} warning={counts.get('warning', 0)}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
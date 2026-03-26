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
    unit_counts = {'clean': 0, 'warning': 0, 'failure': 0}
    acceptance_counts = {'clean': 0, 'warning': 0, 'failure': 0}

    if os.path.isdir(root):
        for current_root, _dirs, files in os.walk(root):
            if 'module-status.json' not in files:
                continue

            path = os.path.join(current_root, 'module-status.json')
            with open(path, 'r', encoding='utf-8') as handle:
                row = json.load(handle)

            rows.append(row)

    rows.sort(key=lambda item: (item.get('lane', 'unit'), item['id'], item.get('acceptance_target', '')))

    unit_rows = [row for row in rows if row.get('lane', 'unit') == 'unit']
    acceptance_rows = [row for row in rows if row.get('lane', 'unit') == 'acceptance']

    for row in unit_rows:
        unit_counts[row['class']] = unit_counts.get(row['class'], 0) + 1
    for row in acceptance_rows:
        acceptance_counts[row['class']] = acceptance_counts.get(row['class'], 0) + 1

    unit_warning_rows = [row for row in unit_rows if row['class'] == 'warning']
    unit_failure_rows = [row for row in unit_rows if row['class'] == 'failure']
    acceptance_warning_rows = [row for row in acceptance_rows if row['class'] == 'warning']
    acceptance_failure_rows = [row for row in acceptance_rows if row['class'] == 'failure']
    metadata_mismatch_rows = [row for row in unit_rows if row.get('metadata_status') != 'supported']

    with open(summary_path, 'a', encoding='utf-8') as summary:
        summary.write('# Compatibility Run Summary\n\n')
        summary.write('## Unit Compatibility (gating)\n\n')
        summary.write('| Module | Class | State | Metadata | Dependency | Documentation |\n')
        summary.write('|---|---|---|---|---|---|\n')
        for row in unit_rows:
            summary.write(
                f"| {row['id']} | {row['class']} | {row['compatibility_state']} | {row['metadata_status']} | {row['dependency_status']} | {row.get('documentation_status', 'unknown')} |\n"
            )

        summary.write('\n')
        summary.write(
            f"**Unit totals:** clean={unit_counts.get('clean', 0)}, warning={unit_counts.get('warning', 0)}, failure={unit_counts.get('failure', 0)}\n"
        )

        if acceptance_rows:
            summary.write('\n## Acceptance Coverage (non-gating)\n\n')
            summary.write('| Module | Target | Class | State | Metadata | Dependency | Documentation |\n')
            summary.write('|---|---|---|---|---|---|---|\n')
            for row in acceptance_rows:
                summary.write(
                    f"| {row['id']} | {row.get('acceptance_target', 'n/a')} | {row['class']} | {row['compatibility_state']} | {row['metadata_status']} | {row['dependency_status']} | {row.get('documentation_status', 'unknown')} |\n"
                )

            summary.write('\n')
            summary.write(
                f"**Acceptance totals:** clean={acceptance_counts.get('clean', 0)}, warning={acceptance_counts.get('warning', 0)}, failure={acceptance_counts.get('failure', 0)}\n"
            )

        if metadata_mismatch_rows:
            summary.write(f'\n**Metadata Notices:** {len(metadata_mismatch_rows)} module(s) have metadata mismatches (see notices for details)\n')

        if unit_warning_rows:
            summary.write('\n## Unit Warnings\n\n')
            for row in unit_warning_rows:
                summary.write(f"- {row['id']}: {row['message']}\n")

        if unit_failure_rows:
            summary.write('\n## Unit Failures\n\n')
            for row in unit_failure_rows:
                summary.write(f"- {row['id']}: {row['message']}\n")

        if acceptance_warning_rows:
            summary.write('\n## Acceptance Warnings\n\n')
            for row in acceptance_warning_rows:
                summary.write(f"- {row['id']} ({row.get('acceptance_target', 'n/a')}): {row['message']}\n")

        if acceptance_failure_rows:
            summary.write('\n## Acceptance Failures\n\n')
            for row in acceptance_failure_rows:
                summary.write(f"- {row['id']} ({row.get('acceptance_target', 'n/a')}): {row['message']}\n")

    if unit_warning_rows:
        print('Unit warnings detected:')
        for row in unit_warning_rows:
            print(f"- {row['id']}: {row['message']}")
            emit('warning', row['id'], row['message'])

    if unit_failure_rows:
        print('Unit failures detected:')
        for row in unit_failure_rows:
            print(f"- {row['id']}: {row['message']}")
            emit('error', row['id'], row['message'])

    if acceptance_warning_rows or acceptance_failure_rows:
        print('Acceptance issues detected:')
        for row in acceptance_warning_rows + acceptance_failure_rows:
            print(f"- {row['id']} ({row.get('acceptance_target', 'n/a')}): {row['message']}")
            emit('warning', f"{row['id']} acceptance {row.get('acceptance_target', 'n/a')}", row['message'])

    if unit_counts.get('warning', 0) > 0:
        emit(
            'warning',
            'Unit compatibility summary',
            f"{unit_counts['warning']} module(s) with warnings; {unit_counts.get('clean', 0)} clean; {unit_counts.get('failure', 0)} failed.",
        )

    if acceptance_rows:
        emit(
            'notice',
            'Acceptance coverage summary',
            f"acceptance clean={acceptance_counts.get('clean', 0)} warning={acceptance_counts.get('warning', 0)} failure={acceptance_counts.get('failure', 0)}",
        )

    if unit_counts.get('failure', 0) > 0:
        emit(
            'error',
            'Unit compatibility summary',
            f"{unit_counts['failure']} module(s) failed; {unit_counts.get('warning', 0)} warning; {unit_counts.get('clean', 0)} clean.",
        )
        return 1

    emit(
        'notice',
        'Unit compatibility summary',
        f"All failing modules cleared. clean={unit_counts.get('clean', 0)} warning={unit_counts.get('warning', 0)}",
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
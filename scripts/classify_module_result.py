import json
import os
import sys


def main() -> int:
    report = os.environ['REPORT']
    status_file = os.environ['STATUS_FILE']
    module_id = os.environ['MODULE_ID']

    payload = {
        'id': module_id,
        'class': 'failure',
        'compatibility_state': 'missing_report',
        'metadata_status': 'unknown',
        'dependency_status': 'unknown',
        'message': 'compatibility-report.json not found',
    }

    if os.path.exists(report):
        with open(report, 'r', encoding='utf-8') as handle:
            parsed = json.load(handle)

        result = (parsed.get('results') or [{}])[0]
        state = result.get('compatibility_state', 'unknown')
        metadata = result.get('metadata_status', 'unknown')
        dependency = result.get('dependency_status', 'none')
        dependency_message = result.get('dependency_message', '')

        if state in ('harness_error', 'not_compatible'):
            klass = 'failure'
        elif dependency == 'warning' or state == 'conditionally_compatible' or metadata != 'supported':
            klass = 'warning'
        else:
            klass = 'clean'

        message = f'state={state} metadata={metadata} dependency={dependency}'
        if dependency_message:
            message = f'{message} {dependency_message}'

        payload = {
            'id': module_id,
            'class': klass,
            'compatibility_state': state,
            'metadata_status': metadata,
            'dependency_status': dependency,
            'message': message,
        }

    with open(status_file, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2)

    print(f"[{payload['id']}] {payload['class']}: {payload['message']}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
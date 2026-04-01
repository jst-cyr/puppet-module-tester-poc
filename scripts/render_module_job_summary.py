import json
import os


def load_json(path: str) -> dict:
    if not os.path.exists(path):
        return {}

    with open(path, 'r', encoding='utf-8') as handle:
        return json.load(handle)


def append_line(path: str, text: str = '') -> None:
    with open(path, 'a', encoding='utf-8') as handle:
        handle.write(text + '\n')


def main() -> int:
    module_id = os.environ['MODULE_ID']
    status_file = os.environ['STATUS_FILE']
    summary_path = os.environ['GITHUB_STEP_SUMMARY']
    artifact_name = os.environ.get('ARTIFACT_NAME', '')
    github_server_url = os.environ.get('GITHUB_SERVER_URL', '')
    github_repository = os.environ.get('GITHUB_REPOSITORY', '')
    github_run_id = os.environ.get('GITHUB_RUN_ID', '')

    artifact_url = ''
    if github_server_url and github_repository and github_run_id:
        artifact_url = f'{github_server_url}/{github_repository}/actions/runs/{github_run_id}#artifacts'

    status = load_json(status_file)
    if not status:
        print(f'[{module_id}] no module-status.json found')
        append_line(summary_path, f'## {module_id}')
        append_line(summary_path, '')
        append_line(summary_path, 'No module status file found.')
        return 0

    summary_class = status.get('class', 'unknown')
    lane = status.get('lane', 'unit')
    acceptance_target = status.get('acceptance_target', '')
    compatibility_state = status.get('compatibility_state', 'unknown')
    metadata_status = status.get('metadata_status', 'unknown')
    metadata_message = status.get('metadata_message', '')
    dependency_status = status.get('dependency_status', 'unknown')
    dependency_message = status.get('dependency_message', '')
    documentation_status = status.get('documentation_status', 'unknown')
    documentation_message = status.get('documentation_message', '')

    lane_suffix = f' target={acceptance_target}' if acceptance_target else ''
    print(f'[{module_id}] lane={lane}{lane_suffix} class={summary_class} state={compatibility_state}')
    if metadata_status != 'supported':
        print(f'- metadata: {metadata_status} {metadata_message}'.strip())
    if dependency_status == 'warning':
        print(f'- dependency: {dependency_message or dependency_status}')
    if documentation_status == 'warning':
        print(f'- documentation: {documentation_message or documentation_status}')

    append_line(summary_path, f'## {module_id}')
    append_line(summary_path, '')
    append_line(summary_path, f'- Lane: {lane}')
    if acceptance_target:
        append_line(summary_path, f'- Acceptance target: {acceptance_target}')
    append_line(summary_path, f'- Class: {summary_class}')
    append_line(summary_path, f'- Compatibility state: {compatibility_state}')
    append_line(summary_path, f'- Metadata: {metadata_status}')
    if metadata_message:
        append_line(summary_path, f'  - {metadata_message}')
    append_line(summary_path, f'- Dependencies: {dependency_status}')
    if dependency_message:
        append_line(summary_path, f'  - {dependency_message}')
    append_line(summary_path, f'- Documentation: {documentation_status}')
    if documentation_message:
        append_line(summary_path, f'  - {documentation_message}')
    if artifact_name:
        append_line(summary_path, f'- Artifact name: {artifact_name}')
    if artifact_url:
        append_line(summary_path, f'- Artifacts: {artifact_url}')
    append_line(summary_path, '')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
"""
prism/prism.py - Cascadia OS v0.34
PRISM: Command center and dashboard aggregation layer.

Owns: aggregating status from all Cascadia OS components,
      surfacing run states, approval queues, dependency blocks,
      crew membership, and system health in one queryable API.
Does not own: execution (FLINT/BEACON/STITCH), storage (VAULT),
              encryption (CURTAIN), communication (BELL/VANGUARD).

PRISM is the window into everything running on Cascadia OS.
A non-technical user should be able to understand the system state
from PRISM alone without reading logs.
"""
# MATURITY: FUNCTIONAL — DB aggregation queries work. Real-time push is v0.35.
from __future__ import annotations

import argparse
from pathlib import Path
import json
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from urllib import request as urllib_request

from cascadia.shared.config import load_config
from cascadia.shared.service_runtime import ServiceRuntime


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _http_get(port: int, path: str, timeout: float = 2.0) -> Optional[Dict[str, Any]]:
    try:
        with urllib_request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None


def _http_post(port: int, path: str, payload: Dict[str, Any], timeout: float = 2.0) -> Optional[Dict[str, Any]]:
    try:
        data = json.dumps(payload).encode()
        req = urllib_request.Request(
            f'http://127.0.0.1:{port}{path}', data=data, method='POST',
            headers={'Content-Type': 'application/json'},
        )
        with urllib_request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None


class PrismService:
    """
    PRISM - Dashboard and command center.
    Owns status aggregation and readable system state.
    Does not own execution, storage, or communication.
    """

    def __init__(self, config_path: str, name: str) -> None:
        self.config = load_config(config_path)
        component = next(c for c in self.config['components'] if c['name'] == name)
        self.runtime = ServiceRuntime(
            name=name, port=component['port'],
            heartbeat_file=component['heartbeat_file'],
            log_dir=self.config['log_dir'],
        )
        # Build port map from config
        self._ports: Dict[str, int] = {
            c['name']: c['port'] for c in self.config['components']
        }
        self._flint_port: int = self.config['flint']['status_port']

        # Register all PRISM routes
        self.runtime.register_route('GET',  '/',                      self.serve_ui)
        self.runtime.register_route('GET',  '/api/prism/overview',    self.overview)
        self.runtime.register_route('GET',  '/api/prism/system',      self.system_status)
        self.runtime.register_route('GET',  '/api/prism/crew',        self.crew_status)
        self.runtime.register_route('GET',  '/api/prism/runs',        self.run_summary)
        self.runtime.register_route('POST', '/api/prism/run',         self.run_detail)
        self.runtime.register_route('GET',  '/api/prism/approvals',   self.pending_approvals)
        self.runtime.register_route('GET',  '/api/prism/blocked',     self.blocked_runs)
        self.runtime.register_route('GET',  '/api/prism/workflows',   self.workflow_list)
        self.runtime.register_route('GET',  '/api/prism/sentinel',    self.sentinel_status)
        self.runtime.register_route('POST', '/api/prism/approve',    self.approve_action)
        self.runtime.register_route('GET',  '/api/prism/models',     self.models_list)
        self.runtime.register_route('GET',  '/api/prism/operators',  self.operator_status)

    # ------------------------------------------------------------------
    # Aggregated views
    # ------------------------------------------------------------------

    def serve_ui(self, _):
        html = (Path(__file__).parent / "prism.html").read_bytes()
        return 200, {"__html__": html}

    def overview(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """
        One-call system snapshot. Everything a non-technical user needs
        to understand what Cascadia OS is doing right now.
        """
        flint = _http_get(self._flint_port, '/api/flint/status') or {}
        crew = _http_get(self._ports.get('crew', 0), '/crew') or {}
        runs = self._get_runs_summary()
        approvals = self._get_pending_approvals()
        blocked = self._get_blocked_runs()

        component_states = {
            c['name']: c.get('process_state', 'unknown')
            for c in flint.get('components', [])
        }
        healthy_count = sum(1 for s in component_states.values() if s == 'ready')
        total_count = len(component_states)

        return 200, {
            'cascadia_os': 'v0.34',
            'generated_at': _now(),
            'system': {
                'flint_state': flint.get('state', 'unknown'),
                'components_healthy': f'{healthy_count}/{total_count}',
                'component_states': component_states,
            },
            'crew': {
                'operator_count': crew.get('crew_size', 0),
                'operators': list(crew.get('operators', {}).keys()),
            },
            'runs': runs,
            'attention_required': {
                'pending_approvals': len(approvals),
                'blocked_runs': len(blocked),
                'approvals': approvals[:5],   # Show first 5
                'blocked': blocked[:5],
            },
        }

    def system_status(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """Full FLINT component status. Includes process_state, health, restart counts."""
        flint = _http_get(self._flint_port, '/api/flint/status') or {}
        sentinel = _http_get(self._ports.get('sentinel', 0), '/risk-levels') or {}
        return 200, {
            'flint': flint,
            'sentinel_rules_loaded': 'risk_levels' in sentinel,
            'generated_at': _now(),
        }

    def crew_status(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """Who is in the Crew and what capabilities they have."""
        crew = _http_get(self._ports.get('crew', 0), '/crew') or {}
        return 200, {
            'crew_size': crew.get('crew_size', 0),
            'operators': crew.get('operators', {}),
            'generated_at': _now(),
        }

    def run_summary(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """Summary of recent runs. Readable by a non-technical user."""
        runs = self._get_runs_summary()
        return 200, {'runs': runs, 'generated_at': _now()}

    def run_detail(self, payload: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """
        Full detail for one run: current step, last failure,
        committed side effects, approval state.
        Reads directly from the durability layer.
        """
        run_id = payload.get('run_id', '')
        if not run_id:
            return 400, {'error': 'run_id required'}

        # Query run_store directly for detailed state
        try:
            from cascadia.durability.run_store import RunStore
            from cascadia.durability.step_journal import StepJournal
            from cascadia.durability.idempotency import IdempotencyManager

            store = RunStore(self.config['database_path'])
            run = store.get_run(run_id)
            if run is None:
                return 404, {'error': 'run not found'}

            journal = StepJournal(store)
            steps = journal.list_steps(run_id)
            idem = IdempotencyManager(store)

            # Get side effects for all steps
            all_effects = []
            for step in steps:
                effects = idem.all_for_step(run_id, step['step_index'])
                all_effects.extend(effects)

            committed = [e for e in all_effects if e['status'] == 'committed']
            pending_approvals = store.pending_approvals(run_id)

            last_completed = next(
                (s for s in reversed(steps) if s.get('completed_at') and not s.get('failure_reason')),
                None,
            )
            last_failed = next(
                (s for s in reversed(steps) if s.get('failure_reason')),
                None,
            )

            return 200, {
                'run_id': run_id,
                'goal': run.get('goal'),
                'run_state': run.get('run_state'),
                'process_state': run.get('process_state'),
                'current_step': run.get('current_step'),
                'retry_count': run.get('retry_count', 0),
                'blocked_reason': run.get('blocked_reason'),
                'blocking_entity': run.get('blocking_entity'),
                'dependency_request': run.get('dependency_request'),
                'last_completed_step': last_completed['step_name'] if last_completed else None,
                'last_failed_step': last_failed['step_name'] if last_failed else None,
                'last_failure_reason': last_failed['failure_reason'] if last_failed else None,
                'committed_side_effects': len(committed),
                'side_effects': [
                    {'action': e['effect_type'], 'target': e['target'], 'status': e['status']}
                    for e in all_effects
                ],
                'pending_approvals': len(pending_approvals),
                'steps_completed': len([s for s in steps if s.get('completed_at') and not s.get('failure_reason')]),
                'total_steps_recorded': len(steps),
            }
        except Exception as exc:
            return 500, {'error': str(exc)}

    def pending_approvals(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """All runs waiting for a human decision. Primary BELL integration point."""
        approvals = self._get_pending_approvals()
        return 200, {
            'count': len(approvals),
            'approvals': approvals,
            'generated_at': _now(),
        }

    def blocked_runs(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """All runs blocked on a missing dependency or permission."""
        blocked = self._get_blocked_runs()
        return 200, {
            'count': len(blocked),
            'blocked': blocked,
            'generated_at': _now(),
        }

    def workflow_list(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """Available STITCH workflows."""
        stitch = _http_get(self._ports.get('stitch', 0), '/workflow/list') or {}
        return 200, {
            'workflows': stitch.get('workflows', []),
            'count': stitch.get('count', 0),
            'generated_at': _now(),
        }

    def sentinel_status(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """SENTINEL risk levels and compliance rules."""
        sentinel = _http_get(self._ports.get('sentinel', 0), '/risk-levels') or {}
        return 200, {**sentinel, 'generated_at': _now()}


    def operator_status(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """Live status of all registered operators from registry.json."""
        import urllib.request as _ur
        registry_path = Path(__file__).parent.parent / "operators" / "registry.json"
        try:
            registry = json.loads(registry_path.read_text())
            operators = registry.get("operators", [])
        except Exception:
            operators = []

        result = []
        for op in operators:
            port = op.get("port")
            health_path = op.get("health_path", "/api/health")
            status = "offline"
            detail = {}
            if port:
                try:
                    with _ur.urlopen(
                        f"http://127.0.0.1:{port}{health_path}", timeout=1
                    ) as r:
                        detail = json.loads(r.read().decode())
                        status = detail.get("status", "online")
                except Exception:
                    status = "offline"
            result.append({
                "id":          op.get("id"),
                "name":        op.get("name"),
                "category":    op.get("category"),
                "description": op.get("description"),
                "status":      status,
                "port":        port,
                "autonomy":    op.get("autonomy"),
                "op_status":   op.get("status"),  # production/beta
                "ui_url":      f"http://localhost:{port}/" if port else None,
                "sample_output": op.get("sample_output"),
            })

        online = sum(1 for o in result if o["status"] != "offline")
        return 200, {
            "operators": result,
            "total": len(result),
            "online": online,
            "generated_at": _now(),
        }



    def models_list(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """
        Return model list from config.
        PRISM reads models directly from config.json so the dashboard
        always reflects what is actually configured — no hardcoding.
        """
        models = self.config.get('models', [])
        llm = self.config.get('llm', {})
        active_id = llm.get('active_model_id', '')

        # If no models in config, return a sensible default
        if not models:
            models = [{
                'id': 'default',
                'name': llm.get('model', 'Local Model'),
                'file': llm.get('model', ''),
                'alias': llm.get('model', ''),
                'desc': 'Configured model · Local',
                'size': '—',
                'context': 4096,
                'recommended_for': 'all tasks',
            }]

        return 200, {
            'models': models,
            'active_model_id': active_id or (models[0]['id'] if models else ''),
            'llm_base_url': llm.get('base_url', 'http://127.0.0.1:8080'),
            'llm_provider': llm.get('provider', 'llamacpp'),
            'count': len(models),
            'generated_at': _now(),
        }

    def approve_action(self, payload: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """
        Record an approval decision from PRISM UI and resume the workflow run.
        Called by the Approve / Reject buttons in the live approvals surface.
        """
        approval_id = payload.get('approval_id')
        decision    = payload.get('decision', '')
        actor       = payload.get('actor', 'prism_operator')
        reason      = payload.get('reason', '')
        run_id      = payload.get('run_id', '')

        if decision not in ('approved', 'denied'):
            return 400, {'error': 'decision must be approved or denied'}
        if approval_id is None:
            return 400, {'error': 'approval_id required'}

        try:
            from cascadia.durability.run_store import RunStore
            from cascadia.system.approval_store import ApprovalStore
            from cascadia.automation.workflow_runtime import WorkflowRuntime
            from cascadia.automation.stitch import WorkflowDefinition, WorkflowStep

            store     = RunStore(self.config['database_path'])
            approvals = ApprovalStore(store)

            # 1. Record the decision — wakes run to 'retrying' if approved
            approvals.record_decision(int(approval_id), decision, actor, reason)

            # 2. If approved, find run_id from approval record and resume
            resume_result: Optional[Dict[str, Any]] = None
            if decision == 'approved':
                if not run_id:
                    with store.connection() as conn:
                        row = conn.execute(
                            'SELECT run_id FROM approvals WHERE id = ?', (approval_id,)
                        ).fetchone()
                    run_id = row['run_id'] if row else ''

                if run_id:
                    definition = WorkflowDefinition(
                        'lead_follow_up', 'Lead Follow-Up', [
                            WorkflowStep('parse_lead',     'main_operator',  'parse_lead'),
                            WorkflowStep('enrich_company', 'main_operator',  'enrich_company'),
                            WorkflowStep('draft_email',    'main_operator',  'draft_email'),
                            WorkflowStep('send_email',     'gmail_operator', 'email.send', on_failure='stop'),
                            WorkflowStep('log_crm',        'main_operator',  'crm.write'),
                        ],
                    )
                    runtime = WorkflowRuntime(self.config['database_path'])
                    result  = runtime.execute('lead_follow_up', definition, {'run_id': run_id})
                    resume_result = result.to_dict()

            return 200, {
                'approval_id': approval_id,
                'decision':    decision,
                'recorded':    True,
                'run_id':      run_id,
                'resume_result': resume_result,
                'generated_at': _now(),
            }
        except Exception as exc:
            return 500, {'error': str(exc)}

    # ------------------------------------------------------------------
    # Internal helpers — query durability layer directly
    # ------------------------------------------------------------------

    def _get_runs_summary(self) -> List[Dict[str, Any]]:
        try:
            from cascadia.durability.run_store import RunStore
            store = RunStore(self.config['database_path'])
            with store.connection() as conn:
                rows = conn.execute(
                    'SELECT run_id, goal, run_state, current_step, retry_count, '
                    'blocked_reason, blocking_entity, created_at, updated_at '
                    'FROM runs ORDER BY updated_at DESC LIMIT 20'
                ).fetchall()
            return [dict(r) for r in rows]
        except Exception:
            return []

    def _get_pending_approvals(self) -> List[Dict[str, Any]]:
        try:
            from cascadia.durability.run_store import RunStore
            store = RunStore(self.config['database_path'])
            with store.connection() as conn:
                rows = conn.execute(
                    'SELECT a.id, a.run_id, a.step_index, a.action_key, '
                    'a.created_at, r.goal '
                    'FROM approvals a '
                    'JOIN runs r ON a.run_id = r.run_id '
                    "WHERE a.decision = 'pending' "
                    'ORDER BY a.created_at ASC'
                ).fetchall()
            return [dict(r) for r in rows]
        except Exception:
            return []

    def _get_blocked_runs(self) -> List[Dict[str, Any]]:
        try:
            from cascadia.durability.run_store import RunStore
            store = RunStore(self.config['database_path'])
            with store.connection() as conn:
                rows = conn.execute(
                    'SELECT run_id, goal, blocked_reason, blocking_entity, '
                    'dependency_request, updated_at '
                    'FROM runs '
                    "WHERE run_state = 'blocked' "
                    'ORDER BY updated_at DESC'
                ).fetchall()
            result = []
            for r in rows:
                d = dict(r)
                if d.get('dependency_request'):
                    try:
                        d['dependency_request'] = json.loads(d['dependency_request'])
                    except Exception:
                        pass
                result.append(d)
            return result
        except Exception:
            return []

    def start(self) -> None:
        self.runtime.logger.info('PRISM dashboard active')
        self.runtime.start()


def main() -> None:
    p = argparse.ArgumentParser(description='PRISM - Cascadia OS dashboard')
    p.add_argument('--config', required=True)
    p.add_argument('--name', required=True)
    a = p.parse_args()
    PrismService(a.config, a.name).start()


if __name__ == '__main__':
    main()

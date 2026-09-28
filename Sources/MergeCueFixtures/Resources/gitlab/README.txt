Provider-native GitLab REST v4 fixture payloads (synthetic data, never live).

Served by `GitLabFixtures.routes(step:)`. File names mirror the endpoint:
- `mr_<project id>_<iid>[_<sub-resource>].json` for /projects/:id/merge_requests/:iid[/…]
- `pipeline_<id>_jobs.json`, `job_<id>_trace.log`, `project_<id>.json`
- `<name>.step1.json` / `<name>.step2.json` override `<name>.json` from that scenario step on
  (step 0 = baseline, step 1 = new blocking comment + failed pipeline, step 2 = reply + pipeline recovered).

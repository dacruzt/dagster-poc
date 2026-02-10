/**
 * Simple web dashboard for the Dagster TS Orchestrator.
 * Serves a real-time view of runs, logs, and sensor status at localhost:3000.
 */

import express from "express";

// ─── Shared State (populated by index.ts) ───────────────────────

export interface RunRecord {
  runKey: string;
  s3Bucket: string;
  s3Key: string;
  taskSize: string;
  fileSizeMb: string;
  taskArn?: string;
  taskId?: string;
  status: "pending" | "running" | "success" | "failed";
  startedAt: string;
  finishedAt?: string;
  exitCode?: number | null;
  error?: string;
}

export interface DashboardState {
  startedAt: string;
  sensorPolls: number;
  lastPollAt: string | null;
  runs: RunRecord[];
  logs: string[];
}

export const state: DashboardState = {
  startedAt: new Date().toISOString(),
  sensorPolls: 0,
  lastPollAt: null,
  runs: [],
  logs: [],
};

const MAX_LOGS = 500;

export function addLog(msg: string) {
  state.logs.push(msg);
  if (state.logs.length > MAX_LOGS) {
    state.logs = state.logs.slice(-MAX_LOGS);
  }
}

// ─── Express Server ─────────────────────────────────────────────

export function startDashboard(port = 3000) {
  const app = express();

  // API endpoints
  app.get("/api/state", (_req, res) => {
    res.json(state);
  });

  app.get("/api/runs", (_req, res) => {
    res.json(state.runs);
  });

  app.get("/api/logs", (_req, res) => {
    res.json(state.logs);
  });

  // HTML Dashboard
  app.get("/", (_req, res) => {
    res.send(renderDashboard());
  });

  app.listen(port, () => {
    addLog(`Dashboard running at http://localhost:${port}`);
  });
}

// ─── HTML Template ──────────────────────────────────────────────

function renderDashboard(): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Dagster TS - Dashboard</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f1117; color: #e0e0e0; }
    .header { background: #1a1d27; padding: 16px 24px; border-bottom: 1px solid #2d3148; display: flex; align-items: center; justify-content: space-between; }
    .header h1 { font-size: 20px; color: #fff; }
    .header h1 span { color: #7c3aed; }
    .header .status { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #9ca3af; }
    .header .dot { width: 8px; height: 8px; border-radius: 50%; background: #22c55e; animation: pulse 2s infinite; }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
    .container { max-width: 1200px; margin: 0 auto; padding: 24px; }
    .stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
    .stat-card { background: #1a1d27; border: 1px solid #2d3148; border-radius: 8px; padding: 16px; }
    .stat-card .label { font-size: 12px; color: #9ca3af; text-transform: uppercase; letter-spacing: 0.5px; }
    .stat-card .value { font-size: 28px; font-weight: 700; color: #fff; margin-top: 4px; }
    .stat-card .value.success { color: #22c55e; }
    .stat-card .value.error { color: #ef4444; }
    .stat-card .value.running { color: #f59e0b; }
    .section { margin-bottom: 24px; }
    .section h2 { font-size: 16px; color: #fff; margin-bottom: 12px; padding-bottom: 8px; border-bottom: 1px solid #2d3148; }
    table { width: 100%; border-collapse: collapse; }
    th { text-align: left; font-size: 11px; color: #9ca3af; text-transform: uppercase; letter-spacing: 0.5px; padding: 8px 12px; border-bottom: 1px solid #2d3148; }
    td { padding: 10px 12px; border-bottom: 1px solid #1e2130; font-size: 13px; }
    tr:hover { background: #1e2130; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; text-transform: uppercase; }
    .badge.success { background: #052e16; color: #22c55e; }
    .badge.failed { background: #450a0a; color: #ef4444; }
    .badge.running { background: #422006; color: #f59e0b; }
    .badge.pending { background: #1e1b4b; color: #818cf8; }
    .badge.small { background: #1e293b; color: #38bdf8; }
    .badge.medium { background: #1e293b; color: #a78bfa; }
    .badge.large { background: #1e293b; color: #fb923c; }
    .badge.xlarge { background: #1e293b; color: #f87171; }
    .logs-box { background: #0a0c10; border: 1px solid #2d3148; border-radius: 8px; padding: 12px; max-height: 350px; overflow-y: auto; font-family: 'SF Mono', 'Fira Code', monospace; font-size: 12px; line-height: 1.6; }
    .logs-box .log-line { white-space: pre-wrap; word-break: break-all; }
    .logs-box .log-line .ts { color: #6b7280; }
    .logs-box .log-line .info { color: #60a5fa; }
    .logs-box .log-line .warn { color: #fbbf24; }
    .logs-box .log-line .err { color: #f87171; }
    .logs-box .log-line .worker { color: #34d399; }
    .empty { text-align: center; padding: 32px; color: #6b7280; }
    .mono { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 12px; }
  </style>
</head>
<body>
  <div class="header">
    <h1><span>Dagster</span> TS Orchestrator</h1>
    <div class="status"><div class="dot"></div><span id="poll-status">Connecting...</span></div>
  </div>
  <div class="container">
    <div class="stats">
      <div class="stat-card"><div class="label">Total Runs</div><div class="value" id="total-runs">0</div></div>
      <div class="stat-card"><div class="label">Success</div><div class="value success" id="success-runs">0</div></div>
      <div class="stat-card"><div class="label">Failed</div><div class="value error" id="failed-runs">0</div></div>
      <div class="stat-card"><div class="label">Running</div><div class="value running" id="running-runs">0</div></div>
    </div>
    <div class="section">
      <h2>Runs</h2>
      <div id="runs-table"><div class="empty">Waiting for sensor data...</div></div>
    </div>
    <div class="section">
      <h2>Logs</h2>
      <div class="logs-box" id="logs-box"><div class="empty">No logs yet...</div></div>
    </div>
  </div>
  <script>
    function colorLog(line) {
      let cls = '';
      if (line.includes('[WORKER]')) cls = 'worker';
      else if (line.includes('[ERROR]')) cls = 'err';
      else if (line.includes('[WARN]')) cls = 'warn';
      else if (line.includes('[INFO]')) cls = 'info';
      return '<div class="log-line ' + cls + '">' + escapeHtml(line) + '</div>';
    }
    function escapeHtml(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }
    function badgeClass(s) { return s || 'pending'; }
    function timeSince(iso) {
      if (!iso) return '-';
      const s = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
      if (s < 60) return s + 's ago';
      if (s < 3600) return Math.floor(s/60) + 'm ago';
      return Math.floor(s/3600) + 'h ago';
    }
    async function refresh() {
      try {
        const res = await fetch('/api/state');
        const data = await res.json();
        document.getElementById('total-runs').textContent = data.runs.length;
        document.getElementById('success-runs').textContent = data.runs.filter(r => r.status === 'success').length;
        document.getElementById('failed-runs').textContent = data.runs.filter(r => r.status === 'failed').length;
        document.getElementById('running-runs').textContent = data.runs.filter(r => r.status === 'running').length;
        document.getElementById('poll-status').textContent = 'Polls: ' + data.sensorPolls + (data.lastPollAt ? ' | Last: ' + timeSince(data.lastPollAt) : '');
        // Runs table
        if (data.runs.length === 0) {
          document.getElementById('runs-table').innerHTML = '<div class="empty">No runs yet. Upload a file to S3 to trigger processing.</div>';
        } else {
          let html = '<table><thead><tr><th>File</th><th>Size</th><th>Task Size</th><th>Status</th><th>Task ID</th><th>Started</th><th>Duration</th></tr></thead><tbody>';
          for (const r of [...data.runs].reverse()) {
            const dur = r.finishedAt ? Math.round((new Date(r.finishedAt).getTime() - new Date(r.startedAt).getTime()) / 1000) + 's' : (r.status === 'running' ? timeSince(r.startedAt).replace(' ago','') : '-');
            html += '<tr>';
            html += '<td class="mono">' + escapeHtml(r.s3Key) + '</td>';
            html += '<td>' + r.fileSizeMb + ' MB</td>';
            html += '<td><span class="badge ' + r.taskSize + '">' + r.taskSize + '</span></td>';
            html += '<td><span class="badge ' + badgeClass(r.status) + '">' + r.status + '</span></td>';
            html += '<td class="mono">' + (r.taskId || '-') + '</td>';
            html += '<td>' + timeSince(r.startedAt) + '</td>';
            html += '<td>' + dur + '</td>';
            html += '</tr>';
          }
          html += '</tbody></table>';
          document.getElementById('runs-table').innerHTML = html;
        }
        // Logs
        const logsBox = document.getElementById('logs-box');
        if (data.logs.length > 0) {
          logsBox.innerHTML = data.logs.map(colorLog).join('');
          logsBox.scrollTop = logsBox.scrollHeight;
        }
      } catch(e) { document.getElementById('poll-status').textContent = 'Connection error'; }
    }
    refresh();
    setInterval(refresh, 2000);
  </script>
</body>
</html>`;
}

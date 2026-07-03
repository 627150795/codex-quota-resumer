#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import {
  appendFileSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 1) {
  const key = process.argv[i];
  if (!key.startsWith('--')) continue;
  const next = process.argv[i + 1];
  args.set(key, next && !next.startsWith('--') ? (i++, next) : true);
}

const threadId = String(args.get('--thread-id') || '');
if (!threadId) throw new Error('Missing --thread-id');

const scriptDir = dirname(fileURLToPath(import.meta.url));
const dataDir = resolve(String(args.get('--data-dir') || join(scriptDir, '.codex-quota-resumer')));
const statePath = resolve(String(args.get('--state') || join(dataDir, 'state.json')));
const backupDir = resolve(String(args.get('--backup-dir') || join(dataDir, 'backups')));
const logPath = resolve(String(args.get('--log') || join(dataDir, 'resumer.log')));
const highRiskPercent = Number(args.get('--high-risk-percent') ?? 95);
const resetBufferMs = Number(args.get('--reset-buffer-ms') ?? 180000);
const turnWaitMs = Number(args.get('--turn-wait-ms') ?? 600000);
const pollLowMs = Number(args.get('--poll-low-ms') ?? 300000);
const pollMidMs = Number(args.get('--poll-mid-ms') ?? 60000);
const pollHighMs = Number(args.get('--poll-high-ms') ?? 15000);
const replayNow = args.get('--replay-now');
const once = Boolean(args.get('--once'));
const notifications = !args.get('--no-notify');

mkdirSync(dirname(statePath), { recursive: true });
mkdirSync(dirname(logPath), { recursive: true });
mkdirSync(backupDir, { recursive: true });

function log(line) {
  const text = `${new Date().toISOString()} ${line}`;
  appendFileSync(logPath, `${text}\n`, 'utf8');
  console.log(text);
}

function notifyUser(title, body) {
  if (!notifications) return;
  log(`notify title=${JSON.stringify(title)} body=${JSON.stringify(body)}`);
  const script = `
Add-Type -AssemblyName System.Windows.Forms
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = [System.Drawing.SystemIcons]::Information
$n.BalloonTipTitle = ${JSON.stringify(title)}
$n.BalloonTipText = ${JSON.stringify(body)}
$n.Visible = $true
$n.ShowBalloonTip(5000)
Start-Sleep -Seconds 6
$n.Dispose()
`;
  const child = spawn('powershell', ['-NoProfile', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], {
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
  });
  child.unref();
}

function queueNotification(type, title, body, dedupeKey) {
  if (!notifications) return;
  const key = `${threadId}:${type}:${dedupeKey || body || title}`;
  if (!state.notificationEvents.some((event) => event.key === key)) {
    state.notificationEvents.push({
      id: `notification-${Date.now()}-${randomUUID()}`,
      key,
      threadId,
      type,
      title,
      body,
      createdAt: new Date().toISOString(),
      shownAt: null,
    });
    saveState();
  }
  notifyUser(title, body);
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, Math.max(0, ms)));
}

function readState() {
  if (!existsSync(statePath)) {
    return { seenUserMessageKeys: [], backups: [], scheduledBackupIds: [], replayedBackupIds: [], replayAttempts: {}, notificationEvents: [] };
  }
  return JSON.parse(readFileSync(statePath, 'utf8').replace(/^\uFEFF/, ''));
}

const state = readState();
const seen = new Set(state.seenUserMessageKeys || []);
const scheduled = new Set(state.scheduledBackupIds || []);
const replayed = new Set(state.replayedBackupIds || []);
state.replayAttempts ||= {};
state.notificationEvents ||= [];
let latestBucket = null;
let highRiskMode = false;
let replayQueue = Promise.resolve();

function saveState() {
  state.seenUserMessageKeys = [...seen];
  state.scheduledBackupIds = [...scheduled];
  state.replayedBackupIds = [...replayed];
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
}

function openServer() {
  const cp = spawn('codex', ['app-server', '--stdio'], { stdio: ['pipe', 'pipe', 'pipe'] });
  let nextId = 1;
  let buf = '';
  let closed = false;
  const pending = new Map();
  const completedEvents = [];
  const completedWaiters = new Set();

  function request(method, params, timeoutMs = 45000) {
    if (closed) return Promise.reject(new Error('app-server is closed'));
    const id = nextId++;
    cp.stdin.write(`${JSON.stringify(params === undefined ? { jsonrpc: '2.0', id, method } : { jsonrpc: '2.0', id, method, params })}\n`);
    return new Promise((resolveRequest, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      pending.set(id, { method, resolve: resolveRequest, reject, timer });
    });
  }

  function notify(method, params) {
    if (closed) return;
    cp.stdin.write(`${JSON.stringify(params === undefined ? { jsonrpc: '2.0', method } : { jsonrpc: '2.0', method, params })}\n`);
  }

  function waitTurnCompleted(waitThreadId, turnId) {
    return new Promise((resolveWait, reject) => {
      let timer;
      const waiter = {
        reject,
        check() {
          const event = completedEvents.find((candidate) => candidate?.threadId === waitThreadId && (!turnId || candidate.turn?.id === turnId));
          if (!event) return;
          clearTimeout(timer);
          completedWaiters.delete(waiter);
          resolveWait(event);
        },
      };
      timer = setTimeout(() => {
        completedWaiters.delete(waiter);
        reject(new Error(`turn/completed timed out: ${turnId || '(any)'}`));
      }, turnWaitMs);
      completedWaiters.add(waiter);
      waiter.check();
    });
  }

  function isTargetThreadEvent(params) {
    return params?.threadId === threadId || params?.turn?.threadId === threadId;
  }

  cp.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    const lines = buf.split(/\r?\n/);
    buf = lines.pop() ?? '';
    for (const line of lines) {
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (error) {
        log(`protocol invalid-json ${error.message}`);
        continue;
      }

      if (msg.id != null && pending.has(msg.id)) {
        const p = pending.get(msg.id);
        pending.delete(msg.id);
        clearTimeout(p.timer);
        msg.error ? p.reject(new Error(`${p.method}: ${msg.error.message}`)) : p.resolve(msg.result);
        continue;
      }

      if (msg.method === 'turn/started' && highRiskMode && isTargetThreadEvent(msg.params)) {
        captureFromItems(msg.params?.turn?.items || [], 'turn-started');
      }
      if (msg.method === 'turn/completed') {
        if (isTargetThreadEvent(msg.params)) {
          completedEvents.push(msg.params);
          if (highRiskMode) captureFromItems(msg.params?.turn?.items || [], 'turn-completed');
          for (const waiter of [...completedWaiters]) waiter.check();
        }
      }
      if (msg.method === 'account/rateLimits/updated') {
        latestBucket = getCodexBucket({ rateLimits: msg.params?.rateLimits });
        highRiskMode = shouldCaptureMessages(latestBucket);
        if (isLimitReached(latestBucket)) schedulePendingBackups(latestBucket);
      }
    }
  });

  cp.stderr.on('data', (chunk) => {
    const text = chunk.toString('utf8').trim();
    if (text && !text.includes('interface.defaultPrompt')) log(`app-server ${text}`);
  });

  cp.on('exit', (code, signal) => {
    closed = true;
    const error = new Error(`app-server exited code=${code} signal=${signal}`);
    for (const p of pending.values()) p.reject(error);
    pending.clear();
    for (const waiter of [...completedWaiters]) waiter.reject(error);
    completedWaiters.clear();
  });

  return { cp, request, notify, waitTurnCompleted, get closed() { return closed; } };
}

function getCodexBucket(limits) {
  return limits?.rateLimitsByLimitId?.codex ?? limits?.rateLimits ?? limits;
}

function usedPercent(bucket) {
  return Number(bucket?.primary?.usedPercent ?? 0);
}

function isLimitReached(bucket) {
  return Boolean(bucket?.rateLimitReachedType) || usedPercent(bucket) >= 100;
}

function shouldCaptureMessages(bucket) {
  return isLimitReached(bucket) || usedPercent(bucket) >= highRiskPercent;
}

function keyForUserMessage(item) {
  return item.clientId || item.id;
}

function textPreview(content) {
  return content
    .filter((part) => part.type === 'text')
    .map((part) => part.text)
    .join('')
    .trim()
    .slice(0, 200);
}

function copyLocalImages(content, backupId) {
  return content.map((part, index) => {
    if (part?.type !== 'localImage' || !part.path || !existsSync(part.path)) return part;
    const target = join(backupDir, `${backupId}-image-${index}${extname(part.path) || '.img'}`);
    copyFileSync(part.path, target);
    return { ...part, originalPath: part.path, path: target };
  });
}

function captureUserMessage(item, source) {
  if (item?.type !== 'userMessage') return;
  const key = keyForUserMessage(item);
  if (!key || seen.has(key)) return;
  if (String(key).startsWith('replay-')) return;
  seen.add(key);

  const backupId = `backup-${Date.now()}-${randomUUID()}`;
  const content = copyLocalImages(item.content || [], backupId);
  const backup = {
    id: backupId,
    status: 'captured',
    source,
    threadId,
    capturedAt: new Date().toISOString(),
    userMessageId: item.id || null,
    clientId: item.clientId || null,
    content,
    textPreview: textPreview(content),
  };
  state.backups.push(backup);
  saveState();
  log(`backup-saved id=${backupId} source=${source} preview=${JSON.stringify(backup.textPreview)}`);
  if (isLimitReached(latestBucket)) {
    queueNotification(
      'backup-saved',
      'Codex task backed up',
      `Quota is exhausted. Saved task: ${backup.textPreview || backupId}`,
      backupId,
    );
  }
}

function captureFromItems(items, source) {
  for (const item of items || []) captureUserMessage(item, source);
}

async function readThreadItems(server) {
  const read = await server.request('thread/read', { threadId, includeTurns: true });
  return (read.thread?.turns || []).flatMap((turn) => turn.items || []);
}

async function markExistingThreadMessagesSeen(server) {
  let count = 0;
  for (const item of await readThreadItems(server)) {
    if (item?.type !== 'userMessage') continue;
    const key = keyForUserMessage(item);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    count += 1;
  }
  saveState();
  log(`baseline-seen userMessages=${count}`);
}

async function captureThreadRead(server, source) {
  captureFromItems(await readThreadItems(server), source);
}

function pendingBackups() {
  return state.backups.filter((backup) => {
    if (backup.threadId !== threadId || replayed.has(backup.id)) return false;
    if (['completed', 'visible_in_thread', 'failed'].includes(backup.status)) return false;
    return (state.replayAttempts[backup.id] || 0) < 2;
  });
}

function schedulePendingBackups(bucket) {
  const resetSeconds = bucket?.primary?.resetsAt;
  if (!resetSeconds) return;
  const dueAt = resetSeconds * 1000 + resetBufferMs;
  const delayMs = Math.max(0, dueAt - Date.now());
  for (const backup of pendingBackups()) {
    if (scheduled.has(backup.id)) continue;
    scheduled.add(backup.id);
    backup.status = 'scheduled';
    backup.scheduledFor = new Date(dueAt).toISOString();
    saveState();
    log(`replay-scheduled backup=${backup.id} due=${backup.scheduledFor} delayMs=${delayMs}`);
    queueNotification(
      'replay-scheduled',
      'Codex replay scheduled',
      `Will retry after quota reset: ${new Date(dueAt).toLocaleString()}`,
      backup.id,
    );
    setTimeout(() => enqueueReplay(backup), delayMs);
  }
}

function restoreScheduledBackups() {
  for (const backup of pendingBackups()) {
    if (!backup.scheduledFor) continue;
    const delayMs = Math.max(0, new Date(backup.scheduledFor).getTime() - Date.now());
    log(`replay-restored backup=${backup.id} due=${backup.scheduledFor} delayMs=${delayMs}`);
    setTimeout(() => enqueueReplay(backup), delayMs);
  }
}

let server;

async function connectServer() {
  const nextServer = openServer();
  const init = await nextServer.request('initialize', {
    clientInfo: { name: 'codex-quota-resumer', version: '1.0.0' },
    capabilities: { experimentalApi: true, requestAttestation: false },
  });
  nextServer.notify('initialized');
  await nextServer.request('thread/resume', { threadId });
  server = nextServer;
  await markExistingThreadMessagesSeen(server);
  restoreScheduledBackups();
  log(`started userAgent=${JSON.stringify(init.userAgent)} thread=${threadId}`);
  return nextServer;
}

function enqueueReplay(backup) {
  replayQueue = replayQueue
    .then(() => replayBackup(backup))
    .catch((error) => log(`replay-error backup=${backup.id} ${error.stack || error.message}`));
}

async function findReplayUserMessage(clientUserMessageId) {
  for (const item of await readThreadItems(server)) {
    if (item?.type === 'userMessage' && keyForUserMessage(item) === clientUserMessageId) return item;
  }
  return null;
}

async function replayBackup(backup) {
  if (replayed.has(backup.id)) return;
  state.replayAttempts[backup.id] = (state.replayAttempts[backup.id] || 0) + 1;
  const attempt = state.replayAttempts[backup.id];
  const clientUserMessageId = `replay-${backup.id}-${attempt}`;
  backup.status = 'submitting';
  backup.lastAttemptAt = new Date().toISOString();
  saveState();

  await server.request('thread/resume', { threadId: backup.threadId });
  const response = await server.request('turn/start', {
    threadId: backup.threadId,
    clientUserMessageId,
    input: backup.content,
  });
  const turnId = response?.turn?.id || null;
  backup.status = 'submitted';
  backup.lastTurnId = turnId;
  backup.lastClientUserMessageId = clientUserMessageId;
  saveState();
  log(`replay-sent backup=${backup.id} turn=${turnId} attempt=${attempt}`);

  await sleep(3000);
  if (await findReplayUserMessage(clientUserMessageId)) {
    replayed.add(backup.id);
    backup.status = 'visible_in_thread';
    backup.visibleAt = new Date().toISOString();
    saveState();
    notifyUser('Codex task replayed', backup.textPreview || backup.id);
  }

  try {
    const turn = (await server.waitTurnCompleted(backup.threadId, turnId))?.turn;
    if (turn?.status === 'completed') backup.status = 'completed';
    backup.lastTurnStatus = turn?.status || 'missing';
    backup.lastTurnError = turn?.error || null;
    saveState();
  } catch (error) {
    backup.lastTurnStatus = 'unknown_after_timeout';
    backup.lastTurnError = error.message;
    saveState();
    log(`replay-wait-timeout backup=${backup.id} turn=${turnId} ${error.message}`);
  }

  if (!replayed.has(backup.id) && !replayNow && attempt < 2) {
    backup.status = 'retry_scheduled';
    saveState();
    setTimeout(() => enqueueReplay(backup), 120000);
  } else if (!replayed.has(backup.id)) {
    backup.status = 'failed';
    saveState();
    notifyUser('Codex replay failed', backup.textPreview || backup.id);
  }
}

function nextPollMs(bucket) {
  const used = usedPercent(bucket);
  if (used >= highRiskPercent) return pollHighMs;
  if (used >= 80) return pollMidMs;
  return pollLowMs;
}

async function readRateLimitsWithRetry(attempts = 3) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await server.request('account/rateLimits/read');
    } catch (error) {
      lastError = error;
      log(`rate-limit-read-error attempt=${attempt}/${attempts} ${error.message}`);
      if (attempt < attempts) await sleep(10000);
    }
  }
  throw lastError;
}

try {
  server = await connectServer();

  if (replayNow) {
    const backup = replayNow === true || replayNow === 'latest'
      ? [...pendingBackups()].pop()
      : state.backups.find((candidate) => candidate.id === replayNow);
    if (!backup) throw new Error(`No backup found for --replay-now ${replayNow}`);
    await replayBackup(backup);
  } else {
    while (true) {
      try {
        latestBucket = getCodexBucket(await readRateLimitsWithRetry());
      } catch (error) {
        log(`server-reconnect ${error.stack || error.message}`);
        try { server.cp.kill(); } catch {}
        await sleep(30000);
        server = await connectServer();
        continue;
      }
      highRiskMode = shouldCaptureMessages(latestBucket);
      log(`rate used=${usedPercent(latestBucket)} reset=${latestBucket?.primary?.resetsAt ? new Date(latestBucket.primary.resetsAt * 1000).toISOString() : 'unknown'} reached=${latestBucket?.rateLimitReachedType || 'none'}`);
      if (highRiskMode) await captureThreadRead(server, 'high-risk-poll');
      if (isLimitReached(latestBucket)) schedulePendingBackups(latestBucket);
      if (once) break;
      await sleep(nextPollMs(latestBucket));
    }
  }
} catch (error) {
  log(`fatal ${error.stack || error.message}`);
  process.exitCode = 1;
} finally {
  if (once || replayNow) server.cp.kill();
}

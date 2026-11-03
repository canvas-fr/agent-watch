import { randomUUID } from 'node:crypto';

const APP_ID = 'dsh';
const TERMINAL_REASONS = new Map([
  ['completed', 'responseEnded'],
  ['error', 'failed'],
  ['aborted', 'cancelled'],
]);
const UNCLASSIFIED_TERMINAL_REASONS = new Set(['blocked', 'max-tokens']);
const USER_QUESTION_TOOL = 'ask_user_question';

function identifier(value) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= 256
    && !/[\u0000-\u001f\u007f]/u.test(value)
    ? value
    : null;
}

function sessionFields(session) {
  const sessionID = identifier(session?.id);
  if (!sessionID) return null;
  const parentSessionID = identifier(session?.header?.parentSession);
  return { sessionID, parentSessionID };
}

function sequenceOf(event) {
  return Number.isSafeInteger(event?.seq) && event.seq >= 0 ? event.seq : undefined;
}

function turnIDOf(value) {
  return Number.isSafeInteger(value) && value >= 0 ? String(value) : null;
}

function makeEvent(session, turnID, state, source, sequence) {
  const fields = sessionFields(session);
  const safeTurnID = identifier(turnID);
  if (!fields || !safeTurnID) return null;
  const result = {
    id: randomUUID(),
    appID: APP_ID,
    sessionID: fields.sessionID,
    turnID: safeTurnID,
    state,
    evidence: 'explicit',
    observedAt: new Date().toISOString(),
    source,
  };
  if (sequence !== undefined) result.sequence = sequence;
  if (fields.parentSessionID) result.parentSessionID = fields.parentSessionID;
  return result;
}

/** Observe only lifecycle metadata; never read event payloads beyond turn and reason tags. */
export function createObserver(writeEvent) {
  const turns = new Map();

  function onSessionEvent(session, event) {
    const fields = sessionFields(session);
    if (!fields || !event || typeof event.type !== 'string') return null;

    if (event.type === 'turn/start') {
      const turnID = turnIDOf(event.data?.turn);
      if (!turnID) return null;
      turns.set(fields.sessionID, { turnID, open: true });
      return writeEvent(makeEvent(session, turnID, 'running', 'dsh:turn/start', sequenceOf(event)));
    }

    if (event.type === 'turn/end') {
      const turnID = turnIDOf(event.data?.turn) ?? turns.get(fields.sessionID)?.turnID;
      const reason = event.data?.reason?.kind;
      const state = TERMINAL_REASONS.get(reason)
        ?? (UNCLASSIFIED_TERMINAL_REASONS.has(reason) ? 'unknown' : null);
      if (!turnID || !state) return null;
      turns.set(fields.sessionID, { turnID, open: false });
      return writeEvent(makeEvent(session, turnID, state, `dsh:turn/end:${reason}`, sequenceOf(event)));
    }

    if (event.type === 'approval/asked') {
      const turn = turns.get(fields.sessionID);
      if (!turn?.open) return null;
      return writeEvent(makeEvent(session, turn.turnID, 'waitingApproval', 'dsh:approval/asked', sequenceOf(event)));
    }

    // Deliberately ignore approval/decided: this adapter observes asks and never handles decisions.
    if (event.type === 'approval/decided') return null;

    if (event.type === 'tool/call') {
      const turn = turns.get(fields.sessionID);
      if (!turn?.open || event.data?.name !== USER_QUESTION_TOOL) return null;
      return writeEvent(makeEvent(
        session,
        turn.turnID,
        'waitingInput',
        `dsh:tool/call:${USER_QUESTION_TOOL}`,
        sequenceOf(event),
      ));
    }

    // These event types carry no prompt or tool arguments; a step or tool result means work resumed.
    if (event.type === 'step/start' || event.type === 'tool/result') {
      const turn = turns.get(fields.sessionID);
      if (!turn?.open) return null;
      return writeEvent(makeEvent(session, turn.turnID, 'running', `dsh:${event.type}`, sequenceOf(event)));
    }
    return null;
  }

  function onAgentStatus(payload) {
    const agent = payload?.agent;
    const fields = sessionFields(agent?.session);
    if (!fields || payload.status !== 'running') return null;
    const turn = turns.get(fields.sessionID);
    // turn/start is the durable boundary. Ignore startup status until it establishes a turn.
    if (!turn?.open) return null;
    return writeEvent(makeEvent(agent.session, turn.turnID, 'running', 'dsh:agent/status:running'));
  }

  function onSessionDisposed(session) {
    const fields = sessionFields(session);
    if (fields) turns.delete(fields.sessionID);
  }

  return { onSessionEvent, onAgentStatus, onSessionDisposed };
}

export const __test = { identifier, sequenceOf, turnIDOf };

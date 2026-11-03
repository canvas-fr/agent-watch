import assert from 'node:assert/strict';
import test from 'node:test';
import { createObserver } from '../mapper.js';

function harness() {
  const events = [];
  const observer = createObserver((event) => {
    if (event) events.push(event);
    return event;
  });
  return { events, observer };
}

function session(id = 'session-1', parentSession = undefined) {
  return { id, header: parentSession ? { parentSession } : {} };
}

test('session turns produce bounded metadata and preserve parent identity', () => {
  const { events, observer } = harness();
  const source = session('child-1', 'parent-1');
  observer.onSessionEvent(source, {
    seq: 2,
    type: 'turn/start',
    data: { turn: 7, prompt: 'SECRET PROMPT', toolArgs: { private: true } },
  });

  assert.equal(events.length, 1);
  assert.equal(events[0].appID, 'dsh');
  assert.equal(events[0].sessionID, 'child-1');
  assert.equal(events[0].parentSessionID, 'parent-1');
  assert.equal(events[0].turnID, '7');
  assert.equal(events[0].state, 'running');
  assert.equal(events[0].sequence, 2);
  assert.equal(events[0].evidence, 'explicit');
  assert.doesNotMatch(JSON.stringify(events), /SECRET PROMPT|toolArgs|private/u);
});

test('agent status is accepted only inside a known open turn', () => {
  const { events, observer } = harness();
  const current = session('session-2');
  const payload = { agent: { id: current.id, session: current }, status: 'running' };
  observer.onAgentStatus(payload);
  assert.equal(events.length, 0, 'status alone cannot invent a turn');

  observer.onSessionEvent(current, { seq: 0, type: 'turn/start', data: { turn: 1 } });
  observer.onAgentStatus(payload);
  assert.equal(events.length, 2);
  assert.equal(events[1].state, 'running');
  assert.equal(events[1].source, 'dsh:agent/status:running');
});

test('session disposal releases its in-memory turn cursor', () => {
  const { events, observer } = harness();
  const current = session('session-disposed');
  observer.onSessionEvent(current, { seq: 0, type: 'turn/start', data: { turn: 1 } });
  observer.onSessionDisposed(current);
  observer.onAgentStatus({ agent: { session: current }, status: 'running' });
  assert.equal(events.length, 1, 'disposed session cannot leave a live turn cursor');
});

test('approval asks notify without copying approval details or decisions', () => {
  const { events, observer } = harness();
  const current = session('session-3');
  observer.onSessionEvent(current, { seq: 1, type: 'turn/start', data: { turn: 2 } });
  observer.onSessionEvent(current, {
    seq: 2,
    type: 'approval/asked',
    data: { id: 'approval-id', toolName: 'shell', reason: 'SECRET REASON', prompt: 'SECRET' },
  });
  observer.onSessionEvent(current, {
    seq: 3,
    type: 'approval/decided',
    data: { id: 'approval-id', outcome: 'allowed-once' },
  });

  assert.equal(events.length, 2);
  assert.equal(events[1].state, 'waitingApproval');
  assert.equal(events[1].source, 'dsh:approval/asked');
  assert.doesNotMatch(JSON.stringify(events), /approval-id|shell|SECRET REASON|SECRET|allowed-once/u);
});

test('only the built-in user question call waits for input and its result resumes work', () => {
  const { events, observer } = harness();
  const current = session('session-user-question');
  observer.onSessionEvent(current, { seq: 0, type: 'turn/start', data: { turn: 3 } });

  function guardedToolEvent(seq, type, name) {
    const forbidden = ['tool_input', 'args', 'body', 'questions'];
    const data = { name };
    const event = { seq, type, data };
    for (const target of [event, data]) {
      for (const field of forbidden) {
        Object.defineProperty(target, field, {
          enumerable: true,
          get() {
            throw new Error(`unexpected read of ${field}`);
          },
        });
      }
    }
    return event;
  }

  observer.onSessionEvent(current, guardedToolEvent(1, 'tool/call', 'shell'));
  observer.onSessionEvent(current, guardedToolEvent(2, 'tool/call', 'ask_user_question_extra'));
  assert.equal(events.length, 1, 'unrecognized tool calls do not create states');

  observer.onSessionEvent(current, guardedToolEvent(3, 'tool/call', 'ask_user_question'));
  assert.equal(events[1].state, 'waitingInput');
  assert.equal(events[1].source, 'dsh:tool/call:ask_user_question');
  assert.equal(events[1].sequence, 3);

  observer.onSessionEvent(current, guardedToolEvent(4, 'tool/result', 'ask_user_question'));
  assert.equal(events[2].state, 'running');
  assert.equal(events[2].source, 'dsh:tool/result');
  assert.equal(events[2].sequence, 4);
  assert.doesNotMatch(JSON.stringify(events), /tool_input|args|body|"questions"/u);
});

test('turn end reasons map only from their fixed tags', () => {
  const { events, observer } = harness();
  const current = session('session-4');
  const cases = [
    ['completed', 'responseEnded'],
    ['error', 'failed'],
    ['aborted', 'cancelled'],
    ['blocked', 'unknown'],
    ['max-tokens', 'unknown'],
  ];
  for (const [index, [reason, expected]] of cases.entries()) {
    const turn = index + 1;
    observer.onSessionEvent(current, { seq: index * 2, type: 'turn/start', data: { turn } });
    observer.onSessionEvent(current, {
      seq: index * 2 + 1,
      type: 'turn/end',
      data: { turn, reason: { kind: reason, error: { message: 'SECRET FAILURE' } } },
    });
    assert.equal(events.at(-1).state, expected);
    if (reason === 'blocked' || reason === 'max-tokens') {
      assert.equal(events.at(-1).source, `dsh:turn/end:${reason}`, 'unknown state retains a fixed reason code');
    }
  }
  assert.doesNotMatch(JSON.stringify(events), /SECRET FAILURE/u);
});

test('invalid identities, unknown reasons, and unrelated events are ignored', () => {
  const { events, observer } = harness();
  observer.onSessionEvent(session('bad\nidentity'), { seq: 0, type: 'turn/start', data: { turn: 1 } });
  const current = session('session-5');
  observer.onSessionEvent(current, { seq: 1, type: 'turn/start', data: { turn: 1 } });
  observer.onSessionEvent(current, { seq: 2, type: 'turn/end', data: { turn: 1, reason: { kind: 'future-kind' } } });
  observer.onSessionEvent(current, { seq: 3, type: 'assistant/message', data: { message: 'secret' } });
  assert.equal(events.length, 1);
  assert.doesNotMatch(JSON.stringify(events), /secret/u);
});

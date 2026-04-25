# Security Policy

## Reporting a vulnerability

Email **mike@otreva.com** with the subject line `[infinite-recall] Security:
<brief description>`.

Do **not** open a public GitHub issue for security vulnerabilities. If you are
uncertain whether something is a security issue, err on the side of emailing.

Expected response: acknowledgment within 72 hours. Standard disclosure window:
**90 days** from first contact, coordinated with any fix.

---

## Threat model

Infinite Recall is local-first. There is no production network surface, no
cloud backend, no user accounts, and no authentication except for the local REST
API. The primary attack surface is a compromised local machine.

### In scope

| Area | Risk |
|------|------|
| **Local storage exposure** | The SQLite database at `~/Library/Application Support/Omi/users/anonymous/omi.db` contains transcripts, memories, action items, and screen-frame summaries. File permissions and TCC grants determine who can read it. |
| **API token on disk** | `~/Library/Application Support/InfiniteRecall/api-token.txt` is a bearer token for the local REST API. It should be mode 0600 (created that way by `setup-api-server.sh`). A world-readable token allows any local process to query the REST API. |
| **MCP API surface** | `Backend-Rust` listens on `127.0.0.1:7331` — loopback only. The bearer token is the sole auth mechanism. Weaknesses in token generation, transmission, or storage are in scope. |
| **TCC permissions** | The app holds Screen Recording and Microphone grants. Privilege escalation that would allow a third party to inherit these grants without user consent is in scope. |
| **LLM sidecar ports** | `mlx-lm.server` (8080) and `mlx-vlm` (8081) listen on loopback. They currently have no auth. A local process can send arbitrary prompts. This is a known limitation; mitigations are welcome. |

### Out of scope

- Anything requiring network access — there is no production network surface.
- Denial-of-service against the local machine (the attacker already has access).
- Speculative / theoretical vulnerabilities in upstream models (WhisperKit,
  MLX models) that have no practical local-machine exploit path.
- Security issues in Omi upstream that have already been removed from this fork
  (Firebase Auth, Deepgram, Firestore, Sentry).

---

## Security-relevant file locations

```
~/Library/Application Support/Omi/users/anonymous/omi.db   (all captured data)
~/Library/Application Support/InfiniteRecall/api-token.txt  (0600, REST bearer token)
~/Library/Logs/InfiniteRecall/                              (app logs — may contain transcripts)
/private/tmp/omi-dev.log                                    (legacy build log path)
```

Ensure these paths are excluded from any backup or sync service you do not
fully trust.

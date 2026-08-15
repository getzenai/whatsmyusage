import Foundation

/// Response *shapes* measured 2026-08-15. Values are placeholders — this repo
/// is meant to go public, so nothing here is an account, an org UUID, an email,
/// or a live reading.
enum Fixtures {
    /// The case the app exists for: 5-hour window empty, weekly limit full.
    static let claudeBlocked = """
    {
      "five_hour": {"limit_dollars": null, "remaining_dollars": null, "resets_at": null,
                    "used_dollars": null, "utilization": 0},
      "seven_day": {"limit_dollars": null, "remaining_dollars": null,
                    "resets_at": "2026-08-17T00:59:59.901091+00:00",
                    "used_dollars": null, "utilization": 100},
      "seven_day_sonnet": null,
      "seven_day_opus": null,
      "amber_ladder": null,
      "tangelo": null,
      "limits": [
        {"group": "session", "is_active": false, "kind": "session", "percent": 0,
         "resets_at": null, "scope": null, "severity": "normal"},
        {"group": "weekly", "is_active": true, "kind": "weekly_all", "percent": 100,
         "resets_at": "2026-08-17T00:59:59.562414+00:00", "scope": null, "severity": "critical"},
        {"group": "weekly", "is_active": false, "kind": "weekly_scoped", "percent": 100,
         "resets_at": "2026-08-17T00:59:59.562627+00:00",
         "scope": {"model": {"display_name": "ExampleModel", "id": null}, "surface": null},
         "severity": "critical"}
      ]
    }
    """

    /// Model-scoped limit higher than the account weekly. The bar must follow the
    /// account number, not the model.
    static let claudeModelHigher = """
    {
      "five_hour": {"resets_at": "2026-08-15T15:50:00.297760+00:00", "utilization": 10},
      "seven_day": {"resets_at": "2026-08-18T14:00:00.297786+00:00", "utilization": 20},
      "limits": [
        {"group": "session", "is_active": false, "kind": "session", "percent": 10,
         "resets_at": "2026-08-15T15:50:00.297760+00:00", "scope": null, "severity": "normal"},
        {"group": "weekly", "is_active": false, "kind": "weekly_all", "percent": 20,
         "resets_at": "2026-08-18T14:00:00.297786+00:00", "scope": null, "severity": "normal"},
        {"group": "weekly", "is_active": true, "kind": "weekly_scoped", "percent": 35,
         "resets_at": "2026-08-18T14:00:00.298004+00:00",
         "scope": {"model": {"display_name": "ExampleModel", "id": null}, "surface": null},
         "severity": "normal"}
      ]
    }
    """

    static let claudePermissionError = """
    {
      "type": "error",
      "request_id": "req_placeholder",
      "error": {
        "type": "permission_error",
        "message": "Invalid authorization for organization",
        "details": {"error_visibility": "user_facing"}
      }
    }
    """

    static let claudeBootstrap = """
    {
      "account": {
        "memberships": [
          {
            "organization": {
              "uuid": "00000000-0000-4000-8000-000000000001",
              "name": "Example Team",
              "rate_limit_tier": "default_raven",
              "capabilities": ["chat", "raven"]
            }
          },
          {
            "organization": {
              "uuid": "00000000-0000-4000-8000-000000000002",
              "name": "Example Max",
              "rate_limit_tier": "default_claude_max_20x",
              "capabilities": ["chat", "claude_max"]
            }
          },
          {
            "organization": {
              "uuid": "00000000-0000-4000-8000-000000000003",
              "name": "Example API Console",
              "rate_limit_tier": "auto_trust_tier_c",
              "capabilities": ["api"]
            }
          }
        ]
      }
    }
    """

    /// Shape of `GET /api/auth/session` when the cookie still mints a backend token.
    static let chatGPTSession = """
    {
      "user": {"name": "Example"},
      "expires": "2026-11-13T00:00:00.000Z",
      "accessToken": "\(sampleChatGPTAccessToken)"
    }
    """

    /// Same endpoint, cookie present but no mint — that is expired, not a later 401.
    static let chatGPTSessionLoggedOut = """
    {
      "user": {"name": "Example"},
      "expires": "2026-11-13T00:00:00.000Z"
    }
    """

    static let chatGPTLocked = """
    {
      "user_id": "user-placeholder",
      "account_id": "acct-placeholder",
      "email": "user@example.com",
      "plan_type": "team",
      "rate_limit": {
        "allowed": false,
        "limit_reached": true,
        "primary_window": {
          "used_percent": 100,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 248662,
          "reset_at": 1787043909
        },
        "secondary_window": null
      },
      "code_review_rate_limit": null,
      "additional_rate_limits": null,
      "credits": {"has_credits": false, "unlimited": false, "overage_limit_reached": false}
    }
    """

    static let chatGPTOpen = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 12,
          "limit_window_seconds": 10800,
          "reset_at": 1786800000
        },
        "secondary_window": {
          "used_percent": 40,
          "limit_window_seconds": 604800,
          "reset_at": 1787043909
        }
      }
    }
    """

    static let grokUnused = """
    {"windowSizeSeconds": 7200, "remainingQueries": 270, "totalQueries": 270,
     "lowEffortRateLimits": null, "highEffortRateLimits": null}
    """

    static let grokEmpty = """
    {"windowSizeSeconds": 7200, "remainingQueries": 0, "totalQueries": 270}
    """

    /// Safari cookie table. Columns are tabs. Contains the two Claude traps:
    /// `sessionKeyLC` (a timestamp) and `routingHint` (`sk-ant-rh-`).
    static let safariClaudeTable = """
    lastActiveOrg\t00000000-0000-4000-8000-000000000002\t.claude.ai\t/\t8/15/2027, 1:24:26 PM\t49 B\t✓\t\tLax
    routingHint\tsk-ant-rh-eyJ0eXAiOiAiSldUIiwgImFsZyI6ICJFUzI1NiJ9.example\t.claude.ai\t/\t9/13/2026, 3:16:57 PM\t471 B\t✓\t✓\tLax
    sessionKey\t\(sampleClaudeKey)\t.claude.ai\t/\t9/11/2026, 3:16:57 PM\t141 B\t✓\t✓\tLax
    sessionKeyLC\t1786713417363\t.claude.ai\t/\t9/11/2026, 3:16:57 PM\t25 B\t✓\t\tLax
    """

    static let safariChatGPTTable = """
    __Secure-next-auth.session-token.1\t\(sampleChatGPTPart1)\t.chatgpt.com\t/\t11/13/2026, 12:23:22 PM\t213 B\t✓\t✓\tLax
    __Secure-next-auth.session-token.0\t\(sampleChatGPTPart0)\t.chatgpt.com\t/\t11/13/2026, 12:23:22 PM\t3.97 KB\t✓\t✓\tLax
    __Host-next-auth.csrf-token\tabc%7Cdef\tchatgpt.com\t/\tSession\t158 B\t✓\t✓\tLax
    """

    static let safariGrokTable = """
    sso\t\(sampleGrokSSO)\t.grok.com\t/\t11/13/2026, 12:23:22 PM\t80 B\t✓\t✓\tLax
    """

    static let sampleClaudeKey = "sk-ant-sid02-EXAMPLEKEYVALUE-0000000000000000000000000000000000000000AA"
    static let sampleChatGPTPart0 = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0.PART0PLACEHOLDER"
    static let sampleChatGPTPart1 = "PART1PLACEHOLDER.suffix"
    static let sampleChatGPTAccessToken = "placeholder-access-token"
    static let sampleGrokSSO = "sso-placeholder-value-xxxxxxxx"
}

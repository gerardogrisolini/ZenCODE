//
//  JiraBrowserSetupPage.swift
//  ZenCODE
//

import Foundation

/// Renders the HTML pages served by the local Jira browser setup flow.
enum JiraSetupPage {
    private static let apiTokenURL = "https://id.atlassian.com/manage-profile/security/api-tokens"

    static func form(
        reason: JiraAuthenticationReason,
        error: String?,
        site: String,
        email: String
    ) -> String {
        let errorBanner = error.map { message in
            "<p class=\"error\">\(escape(message))</p>"
        } ?? ""

        return page(
            title: "Connect Jira",
            body: """
            <h1>Connect Jira</h1>
            <p class="subtitle">\(escape(reason.message))</p>
            \(errorBanner)
            <form method="POST" action="/">
              <label for="site">Jira site URL</label>
              <input id="site" name="site" type="url" placeholder="https://your-domain.atlassian.net" value="\(escape(site))" required autofocus>

              <label for="email">Atlassian email</label>
              <input id="email" name="email" type="email" placeholder="you@example.com" value="\(escape(email))" required>

              <label for="token">Atlassian API token</label>
              <input id="token" name="token" type="password" placeholder="Paste your API token" required>
              <p class="hint">Need a token? <a href="\(apiTokenURL)" target="_blank" rel="noopener">Create an API token</a>, then paste it here.</p>

              <button type="submit">Connect</button>
            </form>
            """
        )
    }

    static func success(accountName: String) -> String {
        page(
            title: "Jira Connected",
            body: """
            <h1>Jira connected</h1>
            <p class="subtitle">Signed in as \(escape(accountName)).</p>
            <p>You can close this tab and return to ZenCODE.</p>
            """
        )
    }

    static let notFound = page(
        title: "Not Found",
        body: """
        <h1>Not found</h1>
        <p>This page does not belong to the Jira setup flow.</p>
        """
    )

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            margin: 0; padding: 48px 16px;
            display: flex; justify-content: center;
          }
          .card {
            width: 100%; max-width: 420px;
            border: 1px solid rgba(128,128,128,0.25); border-radius: 12px;
            padding: 28px 28px 32px;
          }
          h1 { font-size: 22px; margin: 0 0 8px; }
          .subtitle { margin: 0 0 20px; opacity: 0.75; }
          label { display: block; font-size: 13px; font-weight: 600; margin: 16px 0 6px; }
          input {
            width: 100%; box-sizing: border-box; padding: 10px 12px;
            border: 1px solid rgba(128,128,128,0.4); border-radius: 8px; font-size: 14px;
            background: transparent; color: inherit;
          }
          .hint { font-size: 12px; opacity: 0.75; margin: 8px 0 0; }
          button {
            margin-top: 24px; width: 100%; padding: 12px;
            border: 0; border-radius: 8px; font-size: 15px; font-weight: 600;
            background: #2563eb; color: #fff; cursor: pointer;
          }
          button:hover { background: #1d4ed8; }
          .error {
            background: rgba(220,38,38,0.12); color: #dc2626;
            border-radius: 8px; padding: 10px 12px; font-size: 13px; margin: 0 0 12px;
          }
          a { color: #2563eb; }
        </style>
        </head>
        <body>
        <div class="card">
        \(body)
        </div>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

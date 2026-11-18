//
//  FigmaLoginPage.swift
//  ZenCODE
//
//  HTML pages of the local Figma sign-in flow.
//

import Foundation

enum FigmaLoginPage {
    /// Figma account settings, where personal access tokens are generated.
    static let tokenSettingsURL = "https://www.figma.com/settings"
    static let requiredScopes = ["current_user:read", "file_content:read"]
    static let optionalScopes = ["file_metadata:read", "file_variables:read"]

    static func form(reason: FigmaLoginReason, error: String?, formToken: String) -> String {
        let errorBanner = error.map { "<p class=\"error\">\(escape($0))</p>" } ?? ""
        let required = requiredScopes.map { "<code>\(escape($0))</code>" }.joined(separator: ", ")
        let optional = optionalScopes.map { "<code>\(escape($0))</code>" }.joined(separator: ", ")
        return page(
            title: "Sign in to Figma",
            body: """
            <h1>Sign in to Figma</h1>
            <p class="subtitle">\(escape(reason.message))</p>
            \(errorBanner)
            <ol>
              <li>Open <a href="\(tokenSettingsURL)" target="_blank" rel="noopener noreferrer">Figma settings</a>, tab <strong>Security</strong>, section <strong>Personal access tokens</strong>, and click <strong>Generate new token</strong>.</li>
              <li>Grant at least \(required) (\(optional) are optional; variables need an Enterprise plan).</li>
              <li>Paste the token below. ZenCODE verifies it with Figma and keeps it in its private login store.</li>
            </ol>
            <form method="POST" action="/">
              <input type="hidden" name="state" value="\(escape(formToken))">
              <label for="token">Figma access token</label>
              <input id="token" name="token" type="password" placeholder="figd_…" autocomplete="off" spellcheck="false" required autofocus>
              <button type="submit">Sign in</button>
            </form>
            """
        )
    }

    static func success(accountLabel: String) -> String {
        page(
            title: "Signed in to Figma",
            body: """
            <h1>Signed in to Figma</h1>
            <p class="subtitle">Connected as \(escape(accountLabel)).</p>
            <p>You can close this tab and return to ZenCODE.</p>
            """
        )
    }

    static let notFound = page(
        title: "Not Found",
        body: """
        <h1>Not found</h1>
        <p>This page does not belong to the Figma sign-in flow.</p>
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
            width: 100%; max-width: 460px;
            border: 1px solid rgba(128,128,128,0.25); border-radius: 12px;
            padding: 28px 28px 32px;
          }
          h1 { font-size: 22px; margin: 0 0 8px; }
          .subtitle { margin: 0 0 20px; opacity: 0.75; }
          ol { padding-left: 20px; font-size: 14px; line-height: 1.5; }
          li { margin-bottom: 8px; }
          code { font-size: 12px; }
          label { display: block; font-size: 13px; font-weight: 600; margin: 16px 0 6px; }
          input {
            width: 100%; box-sizing: border-box; padding: 10px 12px;
            border: 1px solid rgba(128,128,128,0.4); border-radius: 8px; font-size: 14px;
            background: transparent; color: inherit;
          }
          button {
            margin-top: 24px; width: 100%; padding: 12px;
            border: 0; border-radius: 8px; font-size: 15px; font-weight: 600;
            background: #0d99ff; color: #fff; cursor: pointer;
          }
          button:hover { background: #0b85de; }
          .error {
            background: rgba(220,38,38,0.12); color: #dc2626;
            border-radius: 8px; padding: 10px 12px; font-size: 13px; margin: 0 0 12px;
          }
          a { color: #0d99ff; }
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

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

//
//  WebView.swift
//  blocks-ios
//

import SwiftUI
import WebKit
import Combine

let baseUrl = "https://blocks.insurely.com/"

struct WebView: UIViewRepresentable {
    static var webview: WKWebView?

    let url = URL(string: baseUrl)!
    @ObservedObject var viewModel: ViewModel
    var config: String

    @Environment(\.presentationMode) var presentationMode

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    /// Adds the bootstrap script into the webview to ensure that the postMessaging works as intended.
    func injectBootstrapScript() -> String {
        return """
        (function() {
            const bootstrapScript = document.createElement('script');
            bootstrapScript.id = "insurely-bootstrap-script";
            bootstrapScript.type = "module";
            bootstrapScript.src = "\(baseUrl)assets/mobile-bootstrap.js";
            document.head.appendChild(bootstrapScript);

            window.insurely = \(config)
        })();
        """
    }

    /// Binds the WebView's postMessage to the messageHandler defined below.
    func postMessageMapperScript() -> String {
        return """
        (function() {
            window.originalPostMessage = window.postMessage;
            window.postMessage = function(data, ...rest) {
                window.originalPostMessage(data, ...rest);
                window.webkit.messageHandlers.iOSNative.postMessage(data, ...rest);
            };
        })();
        """
    }

    func makeUIView(context: UIViewRepresentableContext<WebView>) -> WKWebView {
        // Enable javascript in WKWebView to interact with the web app
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = true

        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true

        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        configuration.defaultWebpagePreferences = pagePreferences


        let contentController = WKUserContentController()

        let bootstrapScript = WKUserScript(source: injectBootstrapScript(), injectionTime: WKUserScriptInjectionTime.atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(bootstrapScript)

        // Here "iOSNative" is our interface name that we pushed to the website that is being loaded.
        // This maps to the code in the postMessageMapperScript function.
        let coordinator = makeCoordinator()
        contentController.add(coordinator, name: "iOSNative")

        let postMessageScript = WKUserScript(source: postMessageMapperScript(), injectionTime: WKUserScriptInjectionTime.atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(postMessageScript)

        configuration.userContentController = contentController
        let webview = WKWebView(frame: CGRect.zero, configuration: configuration)
        coordinator.webView = webview
        webview.navigationDelegate = context.coordinator
        webview.allowsBackForwardNavigationGestures = true
        webview.scrollView.isScrollEnabled = true
        webview.load(URLRequest(url: url))

        WebView.webview = webview
        return webview
    }

    func updateUIView(_ webview: WKWebView, context: UIViewRepresentableContext<WebView>) {
    }

    /// Adds a function to allow to send in data to the WebView via postMessage. This is necessary for being able to handle the INSTRUCTIONS.
    func actOnMessage(value: String) {
        let sendSupplementalInformation = """
        (function() {
            window.postMessage({ name: 'SUPPLEMENTAL_INFORMATION', value: \(value) });
        })();
        """
        WebView.webview!.evaluateJavaScript(sendSupplementalInformation)
    }

    class Coordinator : NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var ih = InstructionsHandler()

        var parent: WebView
        var webViewNavigationSubscriber: AnyCancellable? = nil
        var webView: WKWebView?
        init(_ uiWebView: WebView) {
            self.parent = uiWebView
        }

        deinit {
            webViewNavigationSubscriber?.cancel()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Page loaded so no need to show loader anymore
            self.parent.viewModel.showLoader.send(false)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("Terminated")
            parent.viewModel.showLoader.send(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("Failed")
            parent.viewModel.showLoader.send(false)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.viewModel.showLoader.send(true)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.viewModel.showLoader.send(true)
            self.webViewNavigationSubscriber = self.parent.viewModel.webViewNavigationPublisher.receive(on: RunLoop.main).sink(receiveValue: { navigation in
                switch navigation {
                case .backward:
                    if webView.canGoBack {
                        webView.goBack()
                    }
                case .forward:
                    if webView.canGoForward {
                        webView.goForward()
                    }
                case .reload:
                    webView.reload()
                }
            })
        }

        // This function is essential for intercepting every navigation in the webview
        // This code below intercepts external link requests and opens them in default browser
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated  {
                if let url = navigationAction.request.url,
                   UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                    print(url)
                    print("Redirected to browser. No need to open it locally")
                    decisionHandler(.cancel)
                } else {
                    print("Open it locally")
                    decisionHandler(.allow)
                }
            } else {
                decisionHandler(.allow)
            }
        }

        /// Handles INSTRUCTIONS with the InstructionHandler.
        func handleExtraInformation(extraInformation: [String: Any]) {
            guard let instructions = extraInformation["INSTRUCTIONS"] as? [String: Any] else {
                return // handle error here
            }
            if (ih.addInstruction(encoded: instructions) != nil) {
                ih.execute(handler: self.parent.actOnMessage)
            }
        }

        /// Redirects the user to the BankID app.
        func handleOpenBankId(rawUrl: String) {
            guard var bankIDURLComp = URLComponents(string: rawUrl) else {
                return // handle error here
            }
            bankIDURLComp.queryItems?.removeLast()
            bankIDURLComp.queryItems?.append(URLQueryItem(name: "redirect", value: "bankid:///"))
            guard let url = bankIDURLComp.url else {
                return // handle error here
            }
            UIApplication.shared.open(url, options: [:], completionHandler: { success in
                if !success {
                    // Handle failure
                }
            })
        }

        /// Handles the messages sent from the WebView via postMessage.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iOSNative", let body = message.body as? [String: Any] else {
                return // handle error here
            }

            if let extraInformation = body["extraInformation"] as? [String: Any] {
                handleExtraInformation(extraInformation: extraInformation)
            }

            if let name = body["name"] as? String, name == "OPEN_SWEDISH_BANKID", let value = body["value"] as? String {
                handleOpenBankId(rawUrl: value)
            }
        }
    }
}

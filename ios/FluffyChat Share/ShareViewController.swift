// If you get no such module 'receive_sharing_intent' error.
// Go to Build Phases of your Runner target and
// move `Embed Foundation Extension` to the top of `Thin Binary`.
import receive_sharing_intent

class ShareViewController: RSIShareViewController {
      
    // Use this method to return false if you don't want to redirect to host app automatically.
    // Default is true
    override func shouldAutoRedirect() -> Bool {
        return false
    }

    // Workaround to not display post dialog from
    // https://github.com/KasemJaffer/receive_sharing_intent/issues/207#issuecomment-2024329619
    open override func viewDidAppear(_ animated: Bool) {
       super.viewDidAppear(animated)
       // Auto-trigger completion for URLs/text content
       // The parent class processes attachments, but we need to ensure completion
       // when view is hidden, especially for text/URL content
       DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
           // Small delay to allow parent processing to complete
           // Then trigger post to ensure extension completes
           self?.didSelectPost()
       }
   }
    
}

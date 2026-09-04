/* nestly_v755 — Razorpay Checkout opener. External file on purpose: the page's CSP is
   script-src 'self' https://checkout.razorpay.com with NO 'unsafe-inline', so an inline
   <script> block is silently blocked (that is exactly what the first live run showed: the
   page sat on "Opening Razorpay…" forever). Keep every line of behaviour here. */
(function () {
  /* Parameters arrive in the FRAGMENT, never the query string: a fragment is not sent to the
     server and does not reach logs or Referer headers. None of them is a secret — the
     publishable key id, a subscription id and two of our own routes — but there is no reason to
     put them anywhere they will be recorded. */
  var params = new URLSearchParams(location.hash.replace(/^#/, ''));
  var subscriptionId = params.get('sid') || '';
  var keyId = params.get('key') || '';
  var callbackUrl = params.get('cb') || '';
  var cancelUrl = params.get('cancel') || '';
  var description = params.get('desc') || 'Peekaa subscription';
  var name = params.get('name') || 'Peekaa';
  var color = params.get('color') || '#0f766e';
  var button = document.getElementById('pay');
  var error = document.getElementById('err');
  document.getElementById('desc').textContent = description;

  function fail(message) {
    error.textContent = message;
    error.setAttribute('data-shown', '1');
    button.disabled = false;
  }

  function leave(url) {
    /* Only same-origin routes are followed. This is why BILLING_RETURN_ORIGIN must be the SAME
       origin this page is served from — the canonical host, https://www.peekaa.asia (bare
       peekaa.asia 308-redirects to www). Point BILLING_RETURN_ORIGIN at the bare host and every
       cancel route built from it is cross-origin here, so dismissing the payment sheet would
       silently strand the customer on this page instead of returning them to the app. */
    try {
      var target = new URL(url, location.origin);
      if (target.origin !== location.origin) return;
      location.replace(target.toString());
    } catch (e) { /* malformed cancel route: stay on the page */ }
  }

  if (!subscriptionId || !keyId || !callbackUrl) {
    button.disabled = true;
    fail('This payment link is incomplete. Start the subscription again from Peekaa.');
    return;
  }

  var opened = false;
  function open() {
    if (opened) return;
    if (typeof window.Razorpay !== 'function') {
      fail('The payment window could not load. Check your connection and try again.');
      return;
    }
    button.disabled = true;
    try {
      /* redirect:true + callback_url: Razorpay POSTs razorpay_payment_id,
         razorpay_subscription_id and razorpay_signature to razorpay-billing-return, which
         verifies the signature and sends the browser back into the app. Payment truth still
         comes only from the subscription.charged webhook. */
      var checkout = new window.Razorpay({
        key: keyId,
        subscription_id: subscriptionId,
        name: name,
        description: description,
        callback_url: callbackUrl,
        redirect: true,
        theme: { color: color },
        modal: {
          ondismiss: function () {
            button.disabled = false;
            if (cancelUrl) leave(cancelUrl);
          }
        }
      });
      opened = true;
      checkout.open();
    } catch (e) {
      opened = false;
      fail('The payment window could not open. Tap the button to try again.');
    }
  }

  button.addEventListener('click', function () { opened = false; open(); });
  window.addEventListener('load', open);
  if (document.readyState === 'complete') open();
})();

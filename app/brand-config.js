(function initNestlyBrand(globalObject) {
  'use strict';

  const brand = Object.freeze({
    productName: 'Nestly',
    wordmark: 'nestly.',
    customerLabel: 'My Nestly',
    canonicalPublicDomain: 'https://www.nestly.asia',
    downloadPrefix: 'nestly'
  });

  globalObject.NestlyBrand = brand;
  if (typeof module !== 'undefined' && module.exports) module.exports = brand;
})(typeof window !== 'undefined' ? window : globalThis);

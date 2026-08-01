(function initNestlyBrand(globalObject) {
  'use strict';

  const brand = Object.freeze({
    productName: 'Peekaa',
    wordmark: 'peekaa',
    customerLabel: 'My Peekaa',
    canonicalPublicDomain: 'https://www.peekaa.asia',
    contactEmail: 'admin.peekaa@gmail.com',
    logoPath: '/brand/peekaa-logo.png',
    markPath: '/brand/peekaa-mark.png',
    downloadPrefix: 'peekaa'
  });

  globalObject.NestlyBrand = brand;
  if (typeof module !== 'undefined' && module.exports) module.exports = brand;
})(typeof window !== 'undefined' ? window : globalThis);

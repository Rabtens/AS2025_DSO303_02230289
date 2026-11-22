// usms-edge-origin-response
//
// CloudFront trigger point: origin-response.
// Runs after the origin replies and BEFORE the object is cached.

const SECURITY_HEADERS = {
  'strict-transport-security': { key: 'Strict-Transport-Security', value: 'max-age=31536000; includeSubDomains' },
  'x-content-type-options':    { key: 'X-Content-Type-Options',    value: 'nosniff' },
  'x-frame-options':           { key: 'X-Frame-Options',           value: 'DENY' },
  'referrer-policy':           { key: 'Referrer-Policy',           value: 'strict-origin-when-cross-origin' },
  'content-security-policy':  { key: 'Content-Security-Policy',  value: "default-src 'self'" }
};

const TRANSCRIPT_CACHE_CONTROL = 'public, max-age=300, s-maxage=3600';

export const handler = async (event) => {
  const cf = event.Records[0].cf;
  const request = cf.request;
  const response = cf.response;

  // 1. Attach the security headers.
  for (const name of Object.keys(SECURITY_HEADERS)) {
    response.headers[name] = [SECURITY_HEADERS[name]];
  }

  // 2. Transcripts get a deliberate cache policy.
  if (request.uri.startsWith('/transcripts/')) {
    response.headers['cache-control'] = [
      { key: 'Cache-Control', value: TRANSCRIPT_CACHE_CONTROL }
    ];
  }

  // 3. Record whether the viewer-request function ran.
  const upstream = request.headers['x-usms-edge'];
  response.headers['x-usms-edge-chain'] = [
    {
      key: 'X-USMS-Edge-Chain',
      value: upstream && upstream[0] ? `${upstream[0].value};origin-response` : 'origin-response-only'
    }
  ];

  return response;
};

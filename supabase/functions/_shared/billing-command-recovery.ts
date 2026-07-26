export type BillingCommandFailureDisposition = 'failed' | 'uncertain';

export function billingCommandFailureDisposition({
  providerCallStarted,
  nonExecutionProven,
}: {
  providerCallStarted: boolean;
  nonExecutionProven: boolean;
}): BillingCommandFailureDisposition {
  return !providerCallStarted || nonExecutionProven ? 'failed' : 'uncertain';
}

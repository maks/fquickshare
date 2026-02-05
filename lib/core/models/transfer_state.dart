enum TransferState {
  initial,
  waitingForUserConsent,
  receivingFiles,
  sendingFiles,
  finished,
  rejected,
  cancelled,
  error,
}

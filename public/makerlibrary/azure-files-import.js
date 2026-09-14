/* Parse Azure portal connection text as data. No evaluation or command execution. */
(function () {
  'use strict';
  function parseAzureFilesScript(input) {
    if (typeof input !== 'string' || input.length > 32768 || !input.trim()) {
      throw new Error('Paste one Azure Files Windows connection script (up to 32 KB).');
    }
    const text = input.replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ')
      .replace(/^\s*#.*$/gm, '').replace(/`"/g, '"');
    const hostPattern = '[a-z0-9]{3,24}\\.file\\.core\\.windows\\.net';
    function one(regex, label) {
      const matches = [...text.matchAll(regex)];
      if (matches.length !== 1) throw new Error('Expected exactly one ' + label + ' in the script.');
      return matches[0];
    }
    const root = one(/-Root\s+(?:"(\\\\[^"\r\n]+)"|'(\\\\[^'\r\n]+)')/gi, 'quoted share path');
    const unc = root[1] || root[2];
    const match = unc.match(new RegExp('^\\\\\\\\(' + hostPattern + ')\\\\([a-z0-9][a-z0-9-]{1,61}[a-z0-9])\\\\?$', 'i'));
    if (!match || match[2].includes('--')) throw new Error('Use an Azure Files share in Azure public cloud, without a subfolder.');
    const server = match[1].toLowerCase();
    const share = match[2].toLowerCase();
    const account = server.split('.')[0];
    const credentialHost = one(new RegExp('/add:\\s*["\']?(' + hostPattern + ')["\']?(?=\\s|$)', 'gi'), 'cmdkey server')[1].toLowerCase();
    if (credentialHost !== server) throw new Error('The credential server and share server do not match.');
    const user = one(/\/user:\s*(?:"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s"']+))/gi, 'cmdkey username');
    const userText = user[1] || user[2] || user[3];
    if (![account, 'localhost\\' + account, 'azure\\' + account].includes(userText.toLowerCase())) {
      throw new Error('This importer supports storage-account-key scripts; the username must match the storage account.');
    }
    const keyMatch = one(/\/pass:\s*(?:"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s"']+))/gi, 'cmdkey password');
    const key = keyMatch[1] || keyMatch[2] || keyMatch[3];
    if (!/^[A-Za-z0-9+/]{86}==$/.test(key) || atob(key).length !== 64) {
      throw new Error('The account key is missing, masked or invalid. Paste the original account-key connection script.');
    }
    const tests = [...text.matchAll(/-ComputerName\s+["']?([a-z0-9.-]+)["']?/gi)];
    if (tests.length > 1 || (tests.length === 1 && tests[0][1].toLowerCase() !== server)) {
      throw new Error('The connection-test server does not match the share.');
    }
    return {server, share, username: account, password: key, domain: '', smb_version: '3.1.1', smb_kind: 'azure_files'};
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = {parseAzureFilesScript};
  if (typeof document === 'undefined') return;
  if (window.makerlibraryAzureFilesImporterLoaded) return;
  window.makerlibraryAzureFilesImporterLoaded = true;
  document.addEventListener('click', function (event) {
    const button = event.target.closest('[data-import-azure-files]');
    if (!button) return;
    const form = button.closest('form');
    const input = form.querySelector('[data-azure-connect-script]');
    const message = form.querySelector('[data-azure-import-result]');
    try {
      const fields = parseAzureFilesScript(input.value);
      Object.entries(fields).forEach(([name, value]) => {
        const field = form.querySelector('[name="storage_source[' + name + ']"]');
        if (!field) throw new Error('The SMB form is incomplete. Refresh the page.');
        field.value = value;
      });
      const display = form.querySelector('[name="storage_source[display_name]"]');
      const slug = form.querySelector('[name="storage_source[slug]"]');
      if (!display.value.trim()) display.value = 'Azure Files · ' + fields.share;
      if (!slug.value.trim()) slug.value = ('azfiles-' + fields.username + '-' + fields.share).slice(0, 49).replace(/-+$/, '');
      input.value = '';
      message.className = 'alert alert-success mt-3';
      message.textContent = 'Connection details imported. Review the fields below, then test the connection.';
    } catch (error) {
      message.className = 'alert alert-danger mt-3';
      message.textContent = error.message;
    }
    message.hidden = false;
  });
  // The textarea has no name, so it is never submitted with the form. Clear secrets before Turbo caches it.
  document.addEventListener('turbo:before-cache', function () {
    document.querySelectorAll('[data-azure-connect-script], input[name="storage_source[password]"], input[name="storage_source[account_key]"]').forEach(field => { field.value = ''; });
  });
})();

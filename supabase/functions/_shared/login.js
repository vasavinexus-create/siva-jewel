export const usernamePattern = '(?:[A-Za-z0-9_]|-){3,32}';
export const loginDomain = 'sivajewel.example.com';

export function loginEmail(username) {
  const normalized = typeof username === 'string' ? username.trim().toLowerCase() : '';
  if (!new RegExp('^' + usernamePattern + '$').test(normalized)) return null;
  return normalized + '@' + loginDomain;
}

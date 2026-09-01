import { createContext, useContext, useState, type ReactNode } from 'react'

const MOCK_USER = 'demo'
const MOCK_PASS = 'demo'

interface AuthState {
  user: string | null
  login: (username: string, password: string) => boolean
  logout: () => void
}

const AuthContext = createContext<AuthState | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<string | null>(null)

  const login = (username: string, password: string): boolean => {
    if (username === MOCK_USER && password === MOCK_PASS) {
      setUser(username)
      return true
    }
    return false
  }

  const logout = () => setUser(null)

  return (
    <AuthContext.Provider value={{ user, login, logout }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within an AuthProvider')
  return ctx
}

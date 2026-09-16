// 移植自 Android: data/repository/AuthRepository.kt
// 差异:安卓由 Hilt 注入 @Singleton;鸿蒙端用 getInstance() 单例。
// 错误处理(401 清登录态等,即 handleResponse)已折入 HttpClient,行为等价。
import { ApiService } from '../../core/network/ApiService';
import { AuthPreferences } from '../local/AuthPreferences';
import {
  AuthResponse,
  LoginRequest,
  MyInviteCodesResponse,
  SendCodeRequest,
  VerifyInviteRequest,
} from '../model/ApiModels';

export class AuthRepository {
  private static instance: AuthRepository | null = null;

  static getInstance(): AuthRepository {
    if (AuthRepository.instance === null) {
      AuthRepository.instance = new AuthRepository();
    }
    return AuthRepository.instance;
  }

  private apiService: ApiService = ApiService.getInstance();
  private authPrefs: AuthPreferences = AuthPreferences.getInstance();

  async sendCode(email: string): Promise<void> {
    const request: SendCodeRequest = { email: email };
    await this.apiService.sendCode(request);
  }

  async login(email: string, code: string, deviceId: string, hardwareFingerprint: string): Promise<AuthResponse> {
    const request: LoginRequest = {
      email: email,
      code: code,
      device_id: deviceId,
      hardware_fingerprint: hardwareFingerprint,
    };
    const response = await this.apiService.login(request);

    // 保存认证信息
    this.authPrefs.authToken = response.token;
    this.authPrefs.userEmail = response.email;
    this.authPrefs.userTier = response.tier;

    return response;
  }

  async verifyInvite(email: string, inviteCode: string, deviceId: string, hardwareFingerprint: string): Promise<void> {
    const token = this.authPrefs.getAuthHeader();
    const request: VerifyInviteRequest = {
      email: email,
      invite_code: inviteCode,
      device_id: deviceId,
      hardware_fingerprint: hardwareFingerprint,
    };
    const response = await this.apiService.verifyInvite(token, request);

    this.authPrefs.authToken = response.token;
    this.authPrefs.userEmail = response.email;
    this.authPrefs.userTier = response.tier;
  }

  async getMyInviteCodes(): Promise<MyInviteCodesResponse> {
    const token = this.authPrefs.getAuthHeader();
    return this.apiService.getMyInviteCodes(token);
  }

  logout(): void {
    this.authPrefs.clear();
  }

  isLoggedIn(): boolean {
    return this.authPrefs.isLoggedIn;
  }

  getUserEmail(): string | null {
    return this.authPrefs.userEmail;
  }

  getUserTier(): string | null {
    return this.authPrefs.userTier;
  }
}

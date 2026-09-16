// 公共基础设施:@kit.NetworkKit http 封装(契约见 PORTING_GUIDE)。
// 同时折入安卓 di/NetworkModule.kt 的全局配置:
// - 超时:连接 30s / 读 60s(ApiConfig.CONNECT_TIMEOUT/READ_TIMEOUT);
// - 全局 header 拦截器:X-Client-Platform + X-Accept-Language(当前语言 code);
// - handleResponse 扩展的错误处理:401 → 清登录态(仅当 authHeader 为当前值)抛 Unauthorized,
//   403 + USER_BANNED → 清登录态抛 UserBanned,其余非 2xx 抛 HttpError。
// 所有方法返回响应原文 string,由调用方(ApiService)parse。
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiConfig } from './ApiConfig';
import { Logger } from '../log/Logger';
import { MobileStrings } from '../locale/MobileStrings';
import { AuthSession } from '../../data/local/AuthSession';
import { ApiErrorResponse, ApiException, parseApiErrorResponse } from '../../data/model/ApiModels';

const TAG: string = 'HttpClient';

/** multipart 表单分片:文本分片给 data,文件分片给 filePath(+remoteFileName)。 */
export interface MultipartPart {
  name: string;
  contentType: string;
  data?: string;
  filePath?: string;
  remoteFileName?: string;
}

/** 内部请求参数聚合(ArkTS 禁止无类型对象字面量传参)。 */
interface RequestOptions {
  method: http.RequestMethod;
  path: string;
  token?: string;
  contentType?: string;
  extraData?: string | ArrayBuffer;
  multiFormDataList?: Array<http.MultiFormData>;
}

export class HttpClient {
  static async getJson(path: string, token?: string): Promise<string> {
    const options: RequestOptions = {
      method: http.RequestMethod.GET,
      path: path,
      token: token,
    };
    return HttpClient.request(options);
  }

  static async postJson(path: string, body: object, token?: string): Promise<string> {
    const options: RequestOptions = {
      method: http.RequestMethod.POST,
      path: path,
      token: token,
      contentType: 'application/json',
      extraData: JSON.stringify(body),
    };
    return HttpClient.request(options);
  }

  /** POST 无请求体(对应安卓 Retrofit 无 @Body 参数的 @POST,如激活/停用人设)。 */
  static async postNoBody(path: string, token?: string): Promise<string> {
    const options: RequestOptions = {
      method: http.RequestMethod.POST,
      path: path,
      token: token,
    };
    return HttpClient.request(options);
  }

  static async putJson(path: string, body: object, token?: string): Promise<string> {
    const options: RequestOptions = {
      method: http.RequestMethod.PUT,
      path: path,
      token: token,
      contentType: 'application/json',
      extraData: JSON.stringify(body),
    };
    return HttpClient.request(options);
  }

  static async deleteJson(path: string, token?: string): Promise<string> {
    const options: RequestOptions = {
      method: http.RequestMethod.DELETE,
      path: path,
      token: token,
    };
    return HttpClient.request(options);
  }

  /** POST 原始二进制体(如 PCM/WAV 直传场景)。 */
  static async postBinary(path: string, buf: ArrayBuffer, contentType: string, token?: string): Promise<string> {
    const options: RequestOptions = {
      method: http.RequestMethod.POST,
      path: path,
      token: token,
      contentType: contentType,
      extraData: buf,
    };
    return HttpClient.request(options);
  }

  /**
   * POST multipart/form-data(对应安卓 Retrofit @Multipart 音频上传)。
   * 文件分片通过 filePath 引用应用沙箱内文件,文本分片走 data。
   */
  static async postMultipart(path: string, parts: MultipartPart[], token?: string): Promise<string> {
    const formList: Array<http.MultiFormData> = [];
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (p.filePath !== undefined) {
        const item: http.MultiFormData = {
          name: p.name,
          contentType: p.contentType,
          filePath: p.filePath,
          remoteFileName: p.remoteFileName,
        };
        formList.push(item);
      } else {
        const item: http.MultiFormData = {
          name: p.name,
          contentType: p.contentType,
          data: p.data ?? '',
        };
        formList.push(item);
      }
    }
    const options: RequestOptions = {
      method: http.RequestMethod.POST,
      path: path,
      token: token,
      contentType: 'multipart/form-data',
      multiFormDataList: formList,
    };
    return HttpClient.request(options);
  }

  // ==================== 内部实现 ====================

  private static async request(options: RequestOptions): Promise<string> {
    const url = options.path.startsWith('http') ? options.path : `${ApiConfig.BASE_URL}${options.path}`;

    // 等价安卓 clientPlatformInterceptor:统一附加平台与语言 header。
    const header: Record<string, string> = {
      'X-Client-Platform': ApiConfig.CLIENT_PLATFORM,
      'X-Accept-Language': MobileStrings.currentLanguage().code,
    };
    if (options.contentType !== undefined) {
      header['Content-Type'] = options.contentType;
    }
    if (options.token !== undefined && options.token.length > 0) {
      // 调用方传入的是完整 header 值(形如 "Bearer xxx"),与安卓 @Header("Authorization") 一致。
      header['Authorization'] = options.token;
    }
    const httpRequest = http.createHttp();
    try {
      const requestOptions: http.HttpRequestOptions = {
        method: options.method,
        header: header,
        extraData: options.extraData,
        multiFormDataList: options.multiFormDataList,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: ApiConfig.CONNECT_TIMEOUT * 1000,
        readTimeout: ApiConfig.READ_TIMEOUT * 1000,
      };
      const response = await httpRequest.request(url, requestOptions);
      const body: string = typeof response.result === 'string' ? response.result : '';
      const code: number = response.responseCode;
      if (code >= 200 && code < 300) {
        return body;
      }
      HttpClient.throwHttpError(code, body, options.token ?? null);
      // throwHttpError 必抛,此行不可达,仅为满足返回类型。
      return body;
    } catch (err) {
      if (err instanceof ApiException) {
        throw err as Error;
      }
      const e = err as BusinessError;
      Logger.w(TAG, `请求失败 ${options.method} ${url}: ${e.code} ${e.message}`);
      throw ApiException.networkError(e as Error) as Error;
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 等价安卓 NetworkModule.handleResponse:
   * authHeader 用于避免旧请求返回 401 时清掉新登录态。
   */
  private static throwHttpError(code: number, body: string, authHeader: string | null): void {
    let errorResponse: ApiErrorResponse | null = null;
    try {
      if (body.length > 0) {
        errorResponse = parseApiErrorResponse(body);
      }
    } catch (err) {
      errorResponse = null;
    }

    if (code === 401) {
      AuthSession.clearIfCurrent(authHeader);
      throw ApiException.unauthorized() as Error;
    }
    if (code === 403) {
      if (errorResponse !== null && errorResponse.code === 'USER_BANNED') {
        AuthSession.clearIfCurrent(authHeader);
        throw ApiException.userBanned() as Error;
      }
      throw ApiException.httpError(code, errorResponse) as Error;
    }
    throw ApiException.httpError(code, errorResponse) as Error;
  }
}

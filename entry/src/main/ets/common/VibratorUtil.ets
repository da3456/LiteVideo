import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('VibratorUtil');

class VibratorUtil {
  public isAvailable(): boolean {
    return canIUse('SystemCapability.Sensors.MiscDevice');
  }

  private startPreset(effectId: string): void {
    try {
      if (!vibrator.isSupportEffectSync(effectId)) {
        logger.info(`#vibrator#isSupportEffectSync('${effectId}') result is false`);
        return;
      }
      vibrator.startVibration(
        {
          type: 'preset',
          effectId: effectId,
          count: 1,
        },
        {
          usage: 'physicalFeedback'
        }
      );
    } catch (error) {
      const e: BusinessError = error as BusinessError;
      logger.error(`ERROR: #vibrator# ${effectId} Code: ${e.code}, message: ${e.message}`);
    }
  }

  public vibratorTriggerOfHapticClockTimer(): void {
    this.startPreset(vibrator.EffectId.EFFECT_CLOCK_TIMER);
  }

  /** 轻触反馈：订阅/取消订阅成功这类「一次小动作完成」的确认，比时钟震动弱得多。 */
  public vibratorTriggerLight(): void {
    this.startPreset(vibrator.HapticFeedback.EFFECT_SOFT);
  }
}

export const customVibrator = new VibratorUtil();
